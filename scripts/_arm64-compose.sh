#!/usr/bin/env bash
# Shared helpers for the emulated arm64 stack. Sourced, not executed:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/_arm64-compose.sh"
#   C=$(arm64_compose_files)
#
# Everything below that talks to compose uses "$C", so set it first.
#
# Why the file set is worked out here: getting it wrong is silent and expensive.
# Running arm64-recover.sh with the Linux overlay on a Docker Desktop host built
# containers from the STOCK images, and because the FEX binfmt handler is
# registered with flags POC (interpreter resolved per-container at exec time), an
# amd64 image with no FEX baked in cannot exec anything at all -- SQL died with
# `exec /opt/mssql/bin/launch_sqlservr.sh: permission denied` and the recovery loop
# then waited 15 minutes for a container that could never start.
#
# Precedence:
#   1. BC_COMPOSE_FILES  — explicit override, used verbatim. Nothing is added.
#   2. auto-detected     — base + platform overlay + disk + goal.
#   3. BC_COMPOSE_EXTRA  — appended to the auto-detected set (diagnostic overlays).

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
die()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }

# Print the -f arguments for this host. Chatter goes to stderr so the result can
# be captured with $(...).
arm64_compose_files() {
  if [ -n "${BC_COMPOSE_FILES:-}" ]; then
    printf '%s' "$BC_COMPOSE_FILES"
    return 0
  fi

  local files="-f docker-compose.yml" platform="" why=""

  # The discriminator is "is the daemon Docker Desktop", not "is this Windows".
  # Docker Desktop runs its daemon inside its own VM, so docker-compose.arm64.yml's
  # bind-mounts of /usr/bin/FEX and the aarch64 loader would resolve in THAT
  # filesystem, not the host's. Such a daemon needs the overlay whose images carry
  # FEX internally. (Docker Desktop on an Apple Silicon Mac matches too; that host
  # uses Rosetta and MacOS.md, not these scripts.)
  local dockeros
  dockeros=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo '')

  local shellos=no
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) shellos=yes ;;
  esac

  if [ -f docker-compose.arm64-windows.yml ] && \
     { case "$dockeros" in *"Docker Desktop"*) true ;; *) [ "$shellos" = yes ] ;; esac; }; then
    platform="-f docker-compose.arm64-windows.yml"
    why="Docker Desktop daemon — FEX baked into images"
  elif [ -f docker-compose.arm64.yml ]; then
    platform="-f docker-compose.arm64.yml"
    why="Linux host — FEX bind-mounted from the host"
  else
    why="no arm64 overlay found — base compose only"
  fi
  files="$files $platform"

  # Both apply on either platform: storage layout, then the mitigation set. goal
  # stays LAST so its settings win, which is what its header assumes.
  [ -f docker-compose.arm64-disk.yml ] && files="$files -f docker-compose.arm64-disk.yml"
  [ -f docker-compose.arm64-goal.yml ] && files="$files -f docker-compose.arm64-goal.yml"

  [ -n "${BC_COMPOSE_EXTRA:-}" ] && files="$files $BC_COMPOSE_EXTRA"

  printf '[arm64] compose set: %s\n' "$why" >&2
  printf '%s' "$files"
}

ARM64_DB="${BC_DATABASE:-CRONUS}"

# sqlcmd as sa inside the sql container. -b is not optional: without it sqlcmd
# exits 0 when the T-SQL fails, so a failed BACKUP or RESTORE reads as success.
arm64_sql() {
  docker compose $C exec -T sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa \
    -P "${SA_PASSWORD:-Passw0rd123!}" -C -No -b "$@"
}

arm64_state() { docker inspect --format '{{.State.Status}}' "$(docker compose $C ps -aq "$1" 2>/dev/null | head -1)" 2>/dev/null; }
arm64_exit()  { docker inspect --format '{{.State.ExitCode}}' "$(docker compose $C ps -aq "$1" 2>/dev/null | head -1)" 2>/dev/null; }

# SQL is up AND answers a real query. The log line alone is not enough.
arm64_sql_ok() {
  [ "$(arm64_state sql)" = running ] &&
    arm64_sql -h-1 -W -Q "SET NOCOUNT ON; SELECT 'tds_ok'" 2>/dev/null | grep -q tds_ok
}

# (Re)create SQL and retry through its known startup failures. Returns 0 when SQL
# answers a query. The container is RECREATED, never restarted: the data dir is a
# tmpfs, so this always starts from an empty instance (see
# docker-compose.arm64-disk.yml for why that is the safe choice).
#
#   arm64_start_sql <attempts>
arm64_start_sql() {
  local attempts="$1" i t0 verdict st
  for i in $(seq 1 "$attempts"); do
    docker compose $C up -d --no-deps --force-recreate sql >/dev/null 2>&1
    t0=$(date +%s); verdict=""
    while [ $(( $(date +%s) - t0 )) -lt 150 ]; do
      if docker compose $C logs sql 2>/dev/null | grep -qa 'ready for client connections'; then
        verdict=ready; break
      fi
      st=$(arm64_state sql)
      if [ "$st" != running ]; then verdict="died:$(arm64_exit sql)"; break; fi
      sleep 5
    done
    [ -z "$verdict" ] && verdict=hung

    case "$verdict" in
      ready)
        ok "SQL ready in $(( $(date +%s) - t0 ))s (attempt $i)"
        # Prove it with a real query before handing it to BC.
        for _ in 1 2 3 4 5 6; do arm64_sql_ok && return 0; sleep 5; done
        warn "SQL logged ready but does not answer a query — attempt $i/$attempts, recreating" ;;
      died:139)
        # QEMU, not FEX, handled the exec. Retrying cannot help.
        die "SQL segfaulted instantly (exit 139) — that is the QEMU signature.
        binfmt is not pointing at FEX. On Docker Desktop re-run
        scripts/arm64-windows-up.sh; on Linux check /proc/sys/fs/binfmt_misc/FEX-x86_64." ;;
      died:134|died:248)
        warn "SQL hit the known SQLPAL startup crash (exit ${verdict#died:}) — attempt $i/$attempts, recreating" ;;
      died:*)
        warn "SQL exited ${verdict#died:} — attempt $i/$attempts, recreating" ;;
      hung)
        # Container alive, sqlservr at ~1% CPU, only the banner lines printed.
        warn "SQL hung at startup (no 'ready' line in 150s) — attempt $i/$attempts, recreating" ;;
    esac
  done
  return 1
}

# Restore the newest usable backup from /backups (docker-compose.arm64-disk.yml)
# into a fresh SQL, so BC's entrypoint finds the database and skips its restore of
# the pristine artifact .bak. Returns 0 if restored, 1 if there was nothing to
# restore, 2 if every candidate failed. The bctest login needs no fixing: the
# entrypoint creates it on every boot and makes it sysadmin.
#
# Tries the three newest, newest first. arm64-backup.sh only renames a file to
# .bak after BACKUP succeeded, but a file can still be damaged, and CHECKSUM then
# fails the restore. A failed RESTORE can leave the database behind in the
# RESTORING state, and the entrypoint skips its own restore whenever the database
# exists, so the NST would get a database it cannot open. Hence the DROP after
# every failure: either a backup restores, or there is no database at all.
#
# No MOVE clause: the backup was taken from this same container layout, so the
# original file paths (/var/opt/mssql/data/...) are valid in the fresh tmpfs, and
# the logical names are whatever the entrypoint restored (they differ by BC version).
arm64_restore_newest_backup() {
  local f tried=0
  for f in $(docker compose $C exec -T sql sh -c "ls -1t /backups/${ARM64_DB}-*.bak 2>/dev/null | head -3" 2>/dev/null | tr -d '\r'); do
    tried=1
    if arm64_sql -Q "RESTORE DATABASE [$ARM64_DB] FROM DISK='$f' WITH REPLACE, RECOVERY" >/dev/null; then
      ok "restored backup: $f"
      return 0
    fi
    warn "restoring $f failed"
    arm64_sql -Q "IF DB_ID('$ARM64_DB') IS NOT NULL DROP DATABASE [$ARM64_DB]" >/dev/null \
      || die "could not drop the half-restored $ARM64_DB; BC would start against it. Run with --fresh."
  done
  [ "$tried" = 1 ] || return 1
  warn "no backup restored; BC will restore the pristine artifact .bak"
  return 2
}

# bc is running and has printed "Ready for extensions" SINCE ITS LAST START. With
# `restart: on-failure`, a restarted container keeps the earlier boot's log
# lines, so grepping the whole log would call a crashed-and-restarting bc ready.
arm64_bc_ready() {
  local id started
  id=$(docker compose $C ps -q bc 2>/dev/null | head -1)
  [ -n "$id" ] && [ "$(docker inspect --format '{{.State.Status}}' "$id" 2>/dev/null)" = running ] || return 1
  started=$(docker inspect --format '{{.State.StartedAt}}' "$id" 2>/dev/null)
  docker logs --since "$started" "$id" 2>&1 | grep -qa 'Ready for extensions'
}

# Wait for the bc container to print "Ready for extensions" since its last start.
# Fails as soon as bc or sql stops running.
#
#   arm64_wait_bc <timeout-seconds>
arm64_wait_bc() {
  local timeout="$1" t0
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$timeout" ]; do
    if arm64_bc_ready; then
      ok "BC ready in $(( $(date +%s) - t0 ))s"; return 0
    fi
    [ "$(arm64_state bc)" = running ] || die "bc exited ($(arm64_exit bc)) before it was ready. See: docker compose $C logs bc"
    [ "$(arm64_state sql)" = running ] || die "SQL died while BC was booting (exit $(arm64_exit sql)). Run scripts/arm64-recover.sh"
    sleep 10
  done
  die "BC not ready after ${timeout}s. See: docker compose $C logs bc"
}
