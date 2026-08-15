#!/usr/bin/env bash
# Start the BC stack on an arm64 WINDOWS host (Docker Desktop + WSL2), tolerating
# the ways emulated SQL Server fails here.
#
#   scripts/arm64-windows-up.sh [--attempts 5] [--no-backup] [--pull]
#
# What it does, and why each step is not optional:
#
#   1. Preflight   — daemon reachable, daemon arch aarch64, VM memory sane.
#   2. binfmt      — via the compose init service, so FEX (not QEMU) handles
#                    x86-64. Under QEMU, SQL Server dies instantly with
#                    "uncaught target signal 11". Kernel state, lost on every VM
#                    restart, so this re-runs every time.
#   3. Image check — the images must have FEX baked in. With binfmt flags POC an
#                    amd64 image WITHOUT FEX cannot exec anything at all, and says
#                    only "permission denied".
#   4. SQL         — start, then retry through the three known startup failure
#                    modes, reading readiness from SQL's own log rather than a
#                    healthcheck (see below).
#   5. BC          — start, wait for "Ready for extensions".
#   6. Backups     — background loop, so a later SQL death costs minutes.
#
# Readiness is deliberately NOT the docker healthcheck: the stock one runs sqlcmd
# every 5s, and under FEX every invocation is a whole new emulated guest process.
# Removing that poll is associated with SQL going from a 35-minute crash to >20h
# uptime on this box (one observation, host slept twice, near-idle -- see
# docs/ARM64-WINDOWS.md). docker-compose.arm64-windows.yml disables it.
set -uo pipefail
set +H   # `!}` in ${SA_PASSWORD:-Passw0rd123!} is a history event in an interactive shell
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ATTEMPTS=5; DO_BACKUP=1; DO_PULL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --attempts) ATTEMPTS="$2"; shift 2 ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --pull) DO_PULL=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
die()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }

. "$(dirname "${BASH_SOURCE[0]}")/_arm64-compose.sh"
CF=$(arm64_compose_files)
SA="${SA_PASSWORD:-Passw0rd123!}"
AUTH="${BC_SERVER_USERNAME:-BCRUNNER}:${BC_SERVER_PASSWORD:-Admin123!}"

# ── 1. preflight ─────────────────────────────────────────────────────────────
echo "preflight"
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon — is Docker Desktop running?"
ARCH=$(docker info --format '{{.Architecture}}' 2>/dev/null)
case "$ARCH" in
  aarch64|arm64) ok "daemon arch $ARCH" ;;
  *) die "daemon arch is $ARCH, not aarch64 — this script is for arm64 hosts" ;;
esac

# Compose v2: this repo uses `docker compose ... --wait` and per-service
# `platform:`, neither of which docker-compose v1 or podman-compose support.
docker compose version >/dev/null 2>&1 \
  || die "'docker compose' (v2) not available — this stack needs the Compose v2 plugin"
ok "compose v2 $(docker compose version --short 2>/dev/null)"

# One probe container for the remaining VM-side facts, so this costs one
# container start rather than four.
PROBE=$(docker run --rm --platform linux/arm64 alpine:3.20 sh -c \
  'printf "%s|%s|%s\n" "$(getconf PAGESIZE)" "$(awk "/MemTotal/{print \$2}" /proc/meminfo)" "$(grep -m1 Features /proc/cpuinfo | cut -d: -f2)"' 2>/dev/null)
PAGESIZE=${PROBE%%|*}; REST=${PROBE#*|}; VM_KB=${REST%%|*}; CPUFLAGS=${REST#*|}

# FEX emulates x86-64, which assumes 4 KB pages. A 16 KB-page kernel is a
# different problem entirely and fails much later and far less legibly.
if [ "${PAGESIZE:-0}" = 4096 ]; then
  ok "4 KB page size"
else
  die "VM page size is ${PAGESIZE:-unknown}, not 4096 — x86-64 emulation requires 4 KB pages"
fi

# The published images bake fex-emu-armv8.4, which needs FEAT_LSE (atomics) and
# FEAT_LSE2 (uscat). On a CPU without them that build faults with SIGILL, which
# looks like a broken image rather than a CPU mismatch. Snapdragon X has both;
# older Windows-on-ARM parts (SQ1/SQ2) do not.
case "$CPUFLAGS" in
  *uscat*) ok "CPU has FEAT_LSE2 (uscat) — matches the armv8.4 FEX build" ;;
  *)
    warn "CPU does not advertise 'uscat' (FEAT_LSE2), but the published images"
    warn "  bake fex-emu-armv8.4. Expect SIGILL. Rebuild with a lower build:"
    warn "    docker build --platform linux/amd64 -f src/Dockerfile.fex-graft \\"
    warn "      --build-arg BASE_IMAGE=<stock image> --build-arg FEX_PACKAGE=fex-emu-armv8.0 \\"
    warn "      --build-arg FEX_VERSION=<version> -t <tag> src/"
    ;;
esac

# First boot pulls ~3 GB of images and downloads ~2 GB of BC artifacts into
# volumes. Running out mid-restore fails inside SQL and reads as corruption.
DISK_GB=$(docker run --rm --platform linux/arm64 alpine:3.20 sh -c 'df -Pk / | awk "NR==2{print int(\$4/1048576)}"' 2>/dev/null)
if [ -n "$DISK_GB" ] && [ "$DISK_GB" -lt 25 ] 2>/dev/null; then
  warn "only ${DISK_GB} GB free in the VM; first boot needs ~25 GB (images + artifacts + DB)"
elif [ -n "$DISK_GB" ]; then
  ok "${DISK_GB} GB free in the VM"
fi

# The compose mem_limits are 8g (sql) + 14g (bc). If the WSL2 VM is smaller than
# their sum, the VM OOM-kills a container before its own cgroup limit applies --
# and that looks exactly like the emulation corruption this stack is prone to,
# which is a genuinely expensive confusion to debug.
VM_GB=$(( ${VM_KB:-0} / 1048576 ))
if [ "$VM_GB" -ge 22 ]; then
  ok "WSL2 VM memory ${VM_GB} GB"
else
  warn "WSL2 VM has ${VM_GB} GB but the compose limits total 22 GB."
  warn "  Create %UserProfile%\\.wslconfig with:  [wsl2]  memory=24GB"
  warn "  then 'wsl --shutdown' and restart Docker Desktop."
  warn "  Without it a VM-level OOM kill is easily mistaken for emulation corruption."
fi

# ── 2. binfmt (idempotent, must re-run after every VM restart) ────────────────
echo "binfmt"
docker compose $CF up binfmt 2>&1 | sed -n 's/^binfmt-1  | /  /p'
docker compose $CF ps -a --format '{{.Service}} {{.ExitCode}}' 2>/dev/null | grep -q '^binfmt 0' \
  || die "binfmt registration failed — without it SQL Server segfaults instantly under QEMU"

# ── 3. images must actually contain FEX ──────────────────────────────────────
# Checked by extracting the file, NOT by running anything: with POC binfmt, an
# image without FEX cannot exec even /bin/true, so an exec-based probe cannot tell
# "no FEX" apart from "broken binfmt".
echo "images"
[ "$DO_PULL" = 1 ] && docker compose $CF pull -q 2>/dev/null
# Every AMD64 image in the resolved set must contain FEX; arm64 images (the binfmt
# init container) must not and are skipped. Keyed on the image's own architecture
# rather than a hardcoded service list, so this stays correct if a service is added
# -- and note `docker compose config --images <svc>` does NOT filter by service in
# Compose 5.3.1, it prints them all, so a per-service lookup would silently check
# the wrong image.
for img in $(docker compose $CF config --images 2>/dev/null | sort -u); do
  docker image inspect "$img" >/dev/null 2>&1 || {
    echo "  pulling $img ..."
    docker pull -q "$img" >/dev/null 2>&1 || die "cannot pull $img"
  }
  [ "$(docker image inspect --format '{{.Architecture}}' "$img" 2>/dev/null)" = amd64 ] || continue

  # Extract the file rather than exec anything: with POC binfmt an image without
  # FEX cannot exec even /bin/true, so an exec-based probe could not tell "no FEX"
  # apart from "broken binfmt".
  cid=$(docker create "$img" 2>/dev/null) || die "cannot create a container from $img"
  found=1; docker cp "$cid:/usr/bin/FEX" - >/dev/null 2>&1 || found=0
  docker rm -f "$cid" >/dev/null 2>&1
  if [ "$found" = 1 ]; then
    ok "FEX present in $img"
  else
    die "$img has no /usr/bin/FEX.
        With binfmt flags POC every amd64 binary in it fails to exec with a bare
        'permission denied'. Use the published :latest-fex / :2022-fex tags, or build:
          docker build --platform linux/amd64 -f src/Dockerfile.fex-graft \\
            --build-arg BASE_IMAGE=<stock image> -t <tag> src/"
  fi
done

# ── 4. SQL, retried through its three known startup failure modes ────────────
echo "sql"
sql_ready() { docker compose $CF logs sql 2>/dev/null | grep -qa 'ready for client connections'; }
sql_state() { docker inspect --format '{{.State.Status}}' "$(docker compose $CF ps -aq sql 2>/dev/null | head -1)" 2>/dev/null; }
sql_exit()  { docker inspect --format '{{.State.ExitCode}}' "$(docker compose $CF ps -aq sql 2>/dev/null | head -1)" 2>/dev/null; }

started=0
for i in $(seq 1 "$ATTEMPTS"); do
  docker compose $CF up -d --force-recreate sql >/dev/null 2>&1
  t0=$(date +%s); verdict=""
  while [ $(( $(date +%s) - t0 )) -lt 150 ]; do
    if sql_ready; then verdict=ready; break; fi
    st=$(sql_state)
    if [ "$st" != running ]; then verdict="died:$(sql_exit)"; break; fi
    sleep 5
  done
  [ -z "$verdict" ] && verdict=hung

  case "$verdict" in
    ready)
      ok "SQL ready in $(( $(date +%s) - t0 ))s (attempt $i)"; started=1; break ;;
    died:139)
      # QEMU, not FEX, handled the exec. Retrying cannot help.
      die "SQL segfaulted instantly (exit 139) — that is the QEMU signature.
        binfmt is not pointing at FEX. Re-run this script; if it persists check:
          docker run --privileged --rm --platform linux/arm64 alpine:3.20 \\
            sh -c 'mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null; \\
                   cat /proc/sys/fs/binfmt_misc/FEX-x86_64'" ;;
    died:134|died:248)
      warn "SQL hit the known SQLPAL startup crash (exit ${verdict#died:}) — attempt $i/$ATTEMPTS, recreating" ;;
    died:*)
      warn "SQL exited ${verdict#died:} — attempt $i/$ATTEMPTS, recreating" ;;
    hung)
      # Container alive, sqlservr at ~1% CPU, only the banner lines ever printed.
      # Recreating is the documented fix: the tmpfs data dir comes back empty, so
      # there is no crash recovery to wedge on.
      warn "SQL hung at startup (no 'ready' line in 150s) — attempt $i/$ATTEMPTS, recreating" ;;
  esac
done
[ "$started" = 1 ] || die "SQL would not start in $ATTEMPTS attempts. Roughly 1 start in 3 fails
        on this platform; try again, or see docs/ARM64-WINDOWS.md."

# Prove it with a real query before handing it to BC.
docker compose $CF exec -T sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA" \
  -C -No -h-1 -W -Q "SELECT 'tds_ok'" 2>/dev/null | grep -q tds_ok \
  && ok "SQL answers a real TDS query" || warn "SQL logged ready but did not answer a query"

# ── 5. BC ────────────────────────────────────────────────────────────────────
echo "bc"
docker compose $CF up -d bc >/dev/null 2>&1
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 2400 ]; do
  if docker compose $CF logs bc 2>/dev/null | grep -qa 'Ready for extensions'; then
    ok "BC ready in $(( $(date +%s) - t0 ))s"; break
  fi
  if [ "$(sql_state)" != running ]; then
    die "SQL died while BC was booting (exit $(sql_exit)). Run scripts/arm64-recover.sh"
  fi
  sleep 10
done

# ── 6. backups ───────────────────────────────────────────────────────────────
if [ "$DO_BACKUP" = 1 ]; then
  # A PID file, not `pgrep -f`: pgrep is absent or unreliable under Git Bash/MSYS
  # (it silently matched nothing here and started a SECOND loop on top of a
  # running one). `kill -0` against a recorded PID is portable and exact.
  PIDF=/tmp/arm64-backup.pid
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
    ok "backup loop already running (pid $(cat "$PIDF"))"
  else
    nohup bash scripts/arm64-backup.sh --interval 300 --keep 6 >/tmp/arm64-backup.log 2>&1 &
    echo $! > "$PIDF"
    ok "backup loop started (pid $!, every 5 min, keeping 6; log /tmp/arm64-backup.log)"
  fi
fi

echo
echo "endpoints"
# Retry briefly rather than probing once. The web client is started by the
# entrypoint AFTER it prints "Ready for extensions", so a single probe fired at
# that moment reports HTTP 000 for a service that is merely a few seconds behind —
# which reads as a failure on an otherwise perfect run.
probe() {
  local url="$1" code=000 i
  for i in $(seq 1 12); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 20 -u "$AUTH" "$url" 2>/dev/null)
    [ "$code" = 200 ] && break
    sleep 5
  done
  printf '%s' "$code"
}
for u in "http://localhost:${BC_WEBCLIENT_PORT:-8080}/|web client" \
         "http://localhost:${BC_DEV_PORT:-7049}/BC/dev/metadata|dev endpoint" \
         "http://localhost:${BC_ODATA_PORT:-7048}/BC/ODataV4/Company|OData" \
         "http://localhost:${BC_API_PORT:-7052}/BC/api/v2.0/companies|API"; do
  url="${u%%|*}"; label="${u##*|}"
  printf '  %-12s %-52s HTTP %s\n' "$label" "$url" "$(probe "$url")"
done
echo
echo "if SQL dies later:  scripts/arm64-recover.sh   (restores the newest backup)"
