#!/usr/bin/env bash
# Recover the emulated arm64 stack after a SQL Server abort.
#
#   scripts/arm64-recover.sh [--attempts 5] [--fresh]
#
# Why this exists: `restart: on-failure` brings the CONTAINER back, but with the
# tmpfs data dir it comes back EMPTY, and BC then reports a login failure three
# restarts downstream of the real crash. With a persistent data dir instead, the
# restarted sqlservr has to run crash recovery, and under emulation that hangs.
#
# So recovery RECREATES SQL (retrying through its known startup failures),
# restores the newest periodic backup (scripts/arm64-backup.sh) unless --fresh is
# given, and recreates BC so its entrypoint runs against the restored database.
# With no backup, BC restores the pristine artifact .bak and work since first
# boot is lost.
set -uo pipefail
# Disable history expansion: the default SA password ends in `!`; see arm64-backup.sh.
set +H
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ATTEMPTS=5; FRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --attempts) ATTEMPTS="$2"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
. "$(dirname "${BASH_SOURCE[0]}")/_arm64-compose.sh"
C=$(arm64_compose_files)

echo "sql"
docker compose $C stop bc >/dev/null 2>&1
# Docker Desktop: binfmt registration is lost on every VM restart. --no-deps below
# would skip the init service, so run it explicitly.
if docker compose $C config --services 2>/dev/null | grep -qx binfmt; then
  docker compose $C up binfmt >/dev/null 2>&1 || die "binfmt registration failed"
fi
arm64_start_sql "$ATTEMPTS" || die "SQL would not start in $ATTEMPTS attempts; run this again."
if [ "$FRESH" = 0 ]; then
  arm64_restore_newest_backup || [ $? = 2 ] || warn "no backup found; BC will restore the pristine artifact .bak"
fi

echo "bc"
docker compose $C up -d --no-deps --force-recreate bc >/dev/null 2>&1
arm64_wait_bc 2400
echo "  api: HTTP $(curl -s -o /dev/null -w '%{http_code}' -u "${BC_SERVER_USERNAME:-BCRUNNER}:${BC_SERVER_PASSWORD:-Admin123!}" --max-time 60 "http://localhost:${BC_API_PORT:-7052}/BC/api/v2.0/companies")"
