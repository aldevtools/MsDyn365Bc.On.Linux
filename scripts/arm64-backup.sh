#!/usr/bin/env bash
# Periodic CRONUS backups, so a SQL abort costs minutes of work instead of all
# of it.
#
#   scripts/arm64-backup.sh [--interval 900] [--keep 6]
#
# Context: SQL Server under emulation aborts every few hours (measured MTBF ~5h
# on this host). A restarted sqlservr then hangs in crash recovery, so the only
# reliable fix is to recreate it with a fresh data dir — which discards the
# database. That is fine for a demo and NOT fine for development, hence this.
#
# Backups go to a separate volume (/backups) that recovery never touches.
# scripts/arm64-recover.sh restores the newest one; if none exists it falls back
# to BC's own restore from the artifact .bak.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
INTERVAL=900; KEEP=6
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
C="${BC_COMPOSE_FILES:--f docker-compose.yml -f docker-compose.arm64.yml -f docker-compose.arm64-disk.yml -f docker-compose.arm64-goal.yml}"
SA="${SA_PASSWORD:-Passw0rd123!}"
Q() { docker compose $C exec -T sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA" -C -No "$@"; }

echo "[backup] every ${INTERVAL}s, keeping ${KEEP}"
while true; do
  TS=$(date +%Y%m%d-%H%M%S)
  # COPY_ONLY so these never disturb a real backup chain; CHECKSUM so a backup
  # taken from an emulated instance is at least self-verifying.
  if Q -Q "BACKUP DATABASE CRONUS TO DISK='/backups/cronus-$TS.bak' WITH COPY_ONLY, INIT, CHECKSUM, COMPRESSION" >/dev/null 2>&1; then
    echo "[backup] $(date -Is) ok -> cronus-$TS.bak"
    # prune oldest beyond KEEP
    Q -Q "EXEC xp_cmdshell 'ls -1t /backups/cronus-*.bak | tail -n +$((KEEP+1)) | xargs -r rm -f'" >/dev/null 2>&1 ||
      docker compose $C exec -T sql sh -c "ls -1t /backups/cronus-*.bak 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f" >/dev/null 2>&1
  else
    echo "[backup] $(date -Is) FAILED (sql unreachable?)"
  fi
  sleep "$INTERVAL"
done
