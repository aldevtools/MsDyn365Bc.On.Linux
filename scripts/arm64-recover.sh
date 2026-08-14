#!/usr/bin/env bash
# Recover the emulated arm64 stack after a SQL Server abort.
#
# Why this exists: `restart: on-failure` brings the CONTAINER back, but a
# restarted sqlservr then has to run crash recovery on the existing database —
# and under emulation that hangs (observed: container up 1h, sqlservr running at
# 2% CPU, errorlog frozen at the pre-crash timestamp, no new crash dump). The
# container looks alive, SQL never finishes starting, and BC hangs on every
# request while its own healthcheck times out.
#
# So recovery has to RECREATE rather than restart, and discard the data dir: the
# demo database is disposable and BC's entrypoint re-restores CRONUS from the
# artifact .bak in well under a minute. This is the crash-only design the
# original tmpfs data dir implied — persisting the data dir on disk is what
# introduced the recovery step that hangs.
set -uo pipefail
# Disable history expansion: this script contains Passw0rd123!} and an interactive
# or sourced shell expands `!}` as a history event ("bash: !}: event not found"),
# which aborts the assignment and leaves every sqlcmd in here silently
# unauthenticated -- observed as a bogus "no backup found".
set +H
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
. "$(dirname "${BASH_SOURCE[0]}")/_arm64-compose.sh"
C=$(arm64_compose_files)
PROJECT=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

echo "[recover] stopping stack"
docker compose $C down >/dev/null 2>&1

VOL=$(docker volume ls --format '{{.Name}}' | grep -E "${PROJECT}_bc-sqldata$" | head -1)
if [ -n "$VOL" ]; then
  echo "[recover] wiping SQL data volume ($VOL) — this is what unwedges a hung recovery"
  docker volume rm "$VOL" >/dev/null 2>&1 || true
fi

echo "[recover] starting SQL alone (BC must not race the restore)"
docker compose $C up -d sql >/dev/null 2>&1
VOL=$(docker volume ls --format '{{.Name}}' | grep -E "${PROJECT}_bc-sqldata$" | head -1)
[ -n "$VOL" ] && docker compose $C stop sql >/dev/null 2>&1 &&   docker run --rm -v "$VOL":/d alpine chown -R 10001:10001 /d >/dev/null 2>&1 &&   docker compose $C start sql >/dev/null 2>&1

SA="${SA_PASSWORD:-Passw0rd123!}"
Q() { docker compose $C exec -T sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA" -C -No "$@"; }
for i in $(seq 1 40); do Q -Q "SELECT 1" >/dev/null 2>&1 && break; sleep 5; done

# Restore the NEWEST periodic backup if one exists, so a crash costs minutes of
# work rather than everything. Without this the entrypoint restores the pristine
# artifact .bak and every published app / posted document is gone — unacceptable
# for a development box, which is the whole reason arm64-backup.sh exists.
LATEST=$(docker compose $C exec -T sql sh -c 'ls -1t /backups/cronus-*.bak 2>/dev/null | head -1' 2>/dev/null | tr -d '\r')
if [ -n "$LATEST" ]; then
  echo "[recover] restoring newest backup: $LATEST"
  if Q -Q "RESTORE DATABASE CRONUS FROM DISK='$LATEST' WITH MOVE 'Navision_NAV_Data' TO '/var/opt/mssql/data/CRONUS.mdf', MOVE 'Navision_NAV_Log' TO '/var/opt/mssql/data/CRONUS.ldf', REPLACE, RECOVERY" >/dev/null 2>&1; then
    echo "[recover] restored — BC will skip its own restore because CRONUS exists"
  else
    echo "[recover] WARN: backup restore failed; BC will restore the pristine artifact .bak (work since first boot is lost)"
  fi
else
  echo "[recover] no backup found — BC will restore the pristine artifact .bak"
fi

echo "[recover] bringing BC up"
docker compose $C up -d >/dev/null 2>&1

for i in $(seq 1 90); do
  docker compose $C logs bc 2>/dev/null | grep -q "Ready for extensions" && break
  sleep 10
done
docker compose $C ps --format '{{.Service}}  {{.Status}}'
echo "[recover] api=$(curl -s -o /dev/null -w '%{http_code}' -u "${BC_SERVER_USERNAME:-BCRUNNER}:${BC_SERVER_PASSWORD:-Admin123!}" --max-time 60 http://localhost:${BC_API_PORT:-7052}/BC/api/v2.0/companies)"
