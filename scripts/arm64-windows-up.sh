#!/usr/bin/env bash
# Start the BC stack on an arm64 WINDOWS host (Docker Desktop + WSL2), tolerating
# the ways emulated SQL Server fails here.
#
#   scripts/arm64-windows-up.sh [--attempts 5] [--fresh] [--no-backup] [--pull]
#
# Safe to re-run: if SQL and BC are already up and answering, nothing is
# restarted. What it does, and why each step is not optional:
#
#   1. Preflight   — daemon reachable, daemon arch aarch64, VM memory and CPUs sane.
#   2. binfmt      — via the compose init service, so FEX (not QEMU) handles
#                    x86-64. Under QEMU, SQL Server dies instantly with
#                    "uncaught target signal 11". Kernel state, lost on every VM
#                    restart, so this re-runs every time.
#   3. Image check — the images must have FEX baked in. With binfmt flags POC an
#                    amd64 image WITHOUT FEX cannot exec anything at all, and says
#                    only "permission denied".
#   4. SQL         — if it is not up, recreate it and retry through the known
#                    startup failure modes (roughly 1 start in 3 fails), then
#                    restore the newest backup unless --fresh is given.
#   5. BC          — recreated whenever SQL was, then wait for "Ready for extensions".
#   6. Backups     — background loop, so a later SQL death costs minutes.
#
# Readiness is read from SQL's own log plus one real query, not a docker
# healthcheck: a healthcheck polls with sqlcmd, and under emulation every
# invocation is a whole new emulated process. Removing that poll is associated
# with SQL going from a 35-minute crash to >20h uptime (one observation, see
# docs/ARM64-WINDOWS.md). docker-compose.arm64-goal.yml disables it.
set -uo pipefail
set +H   # `!}` in ${SA_PASSWORD:-Passw0rd123!} is a history event in an interactive shell
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ATTEMPTS=5; DO_BACKUP=1; DO_PULL=0; FRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --attempts) ATTEMPTS="$2"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --pull) DO_PULL=1; shift ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

. "$(dirname "${BASH_SOURCE[0]}")/_arm64-compose.sh"
C=$(arm64_compose_files)
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
  'printf "%s|%s|%s|%s\n" "$(getconf PAGESIZE)" "$(awk "/MemTotal/{print \$2}" /proc/meminfo)" "$(nproc)" "$(grep -m1 Features /proc/cpuinfo | cut -d: -f2)"' 2>/dev/null)
PAGESIZE=${PROBE%%|*}; REST=${PROBE#*|}; VM_KB=${REST%%|*}; REST=${REST#*|}
VM_CPUS=${REST%%|*}; CPUFLAGS=${REST#*|}

# docker-compose.arm64-goal.yml pins SQL to CPUs 0-3 (BC_SQL_CPUSET). On a VM with
# fewer CPUs, container creation fails with "Requested CPUs are not available".
if [ -z "${BC_SQL_CPUSET:-}" ] && [ "${VM_CPUS:-0}" -lt 4 ] 2>/dev/null; then
  die "the VM has ${VM_CPUS} CPUs, but SQL is pinned to CPUs 0-3 by default.
        Set BC_SQL_CPUSET=0-$(( VM_CPUS - 1 )) or give the VM more processors in .wslconfig."
fi

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

# The compose mem_limits are 10g (sql) + 12g (bc). If the WSL2 VM is smaller than
# their sum, the VM OOM-kills a container before its own cgroup limit applies --
# and that looks exactly like the emulation corruption this stack is prone to,
# which is a genuinely expensive confusion to debug.
VM_GB=$(( ${VM_KB:-0} / 1048576 ))
if [ "$VM_GB" -ge 22 ]; then
  ok "WSL2 VM memory ${VM_GB} GB"
else
  warn "WSL2 VM has ${VM_GB} GB but the compose mem_limits total 22 GB (sql 10g + bc 12g)."
  warn "  This is arithmetic, NOT a measured minimum -- BC's working set is well under"
  warn "  12g, and nothing here has been tested in a smaller VM. What matters is that"
  warn "  the VM be at least the SUM of the limits, so a container that overruns hits"
  warn "  its OWN cgroup limit and dies attributably, instead of the VM's OOM killer"
  warn "  picking a victim -- which is indistinguishable from the emulation corruption"
  warn "  this stack is already prone to."
  warn "  Either raise the VM:  %UserProfile%\\.wslconfig -> [wsl2] memory=24GB,"
  warn "                        then 'wsl --shutdown' and restart Docker Desktop"
  warn "  or lower the caps:    mem_limit in docker-compose.arm64-windows.yml"
fi

# ── 2. binfmt (idempotent, must re-run after every VM restart) ────────────────
echo "binfmt"
docker compose $C up binfmt 2>&1 | sed -n 's/^binfmt[^|]*| /  /p'
docker compose $C ps -a --format '{{.Service}} {{.ExitCode}}' 2>/dev/null | grep -q '^binfmt 0' \
  || die "binfmt registration failed — without it SQL Server segfaults instantly under QEMU"

# ── 3. images must actually contain FEX ──────────────────────────────────────
# Checked by extracting the file, NOT by running anything: with POC binfmt, an
# image without FEX cannot exec even /bin/true, so an exec-based probe cannot tell
# "no FEX" apart from "broken binfmt".
echo "images"
[ "$DO_PULL" = 1 ] && docker compose $C pull -q 2>/dev/null
# Every AMD64 image in the resolved set must contain FEX; arm64 images (the binfmt
# init container) must not and are skipped. Keyed on the image's own architecture
# rather than a hardcoded service list, so this stays correct if a service is added
# -- and note `docker compose config --images <svc>` does NOT filter by service in
# Compose 5.3.1, it prints them all, so a per-service lookup would silently check
# the wrong image.
for img in $(docker compose $C config --images 2>/dev/null | sort -u); do
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

# ── 4. SQL: keep a live one, otherwise recreate and restore ──────────────────
# Recreating SQL empties its tmpfs data dir, so it only happens when SQL is not
# already up and answering. Re-running this script on a healthy stack (to check
# it, or after closing the terminal) must not cost the database.
echo "sql"
SQL_NEW=0
if arm64_sql_ok; then
  ok "SQL already up and answering — left as is"
else
  arm64_start_sql "$ATTEMPTS" || die "SQL would not start in $ATTEMPTS attempts. Roughly 1 start in 3
        fails on this platform; try again, or see docs/ARM64-WINDOWS.md."
  SQL_NEW=1
  if [ "$FRESH" = 0 ]; then
    arm64_restore_newest_backup || [ $? = 2 ] || ok "no backup yet; BC restores the demo database"
  fi
fi

# ── 5. BC ────────────────────────────────────────────────────────────────────
# A bc that outlived its SQL holds an NST pointed at a database that no longer
# exists, so it is recreated whenever SQL was. Recreating also means the log
# only holds this boot's lines, so "Ready for extensions" cannot come from an
# older container.
echo "bc"
if [ "$SQL_NEW" = 0 ] && [ "$(arm64_state bc)" = running ] \
   && docker compose $C logs bc 2>/dev/null | grep -qa 'Ready for extensions'; then
  ok "BC already up — left as is"
else
  docker compose $C up -d --no-deps --force-recreate bc >/dev/null 2>&1
  arm64_wait_bc 2400
fi

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
  local url="$1" code=000
  for _ in $(seq 1 12); do
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
