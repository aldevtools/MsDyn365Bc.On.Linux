#!/usr/bin/env bash
# Periodic backups of the BC database, so a SQL abort costs minutes of work
# instead of all of it.
#
#   scripts/arm64-backup.sh [--interval 900] [--keep 6]
#
# Context: SQL Server under emulation aborts every few hours (measured MTBF ~5h
# on this host). A restarted sqlservr then hangs in crash recovery, so the only
# reliable fix is to recreate it with a fresh data dir — which discards the
# database. That is fine for a demo and NOT fine for development, hence this.
#
# Backups go to a separate volume (/backups, docker-compose.arm64-disk.yml) that
# recovery never touches. scripts/arm64-recover.sh and arm64-windows-up.sh restore
# the newest one; if none exists BC restores the pristine artifact .bak.
set -uo pipefail
# Disable history expansion: the default SA password ends in `!` and an interactive
# or sourced shell expands `!}` as a history event ("bash: !}: event not found"),
# which aborts the assignment and leaves every sqlcmd in here silently
# unauthenticated -- observed as a bogus "no backup found".
set +H
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
INTERVAL=900; KEEP=6
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
. "$(dirname "${BASH_SOURCE[0]}")/_arm64-compose.sh"
C=$(arm64_compose_files)

echo "[backup] $ARM64_DB every ${INTERVAL}s, keeping ${KEEP}"
while true; do
  TS=$(date +%Y%m%d-%H%M%S)
  F="/backups/${ARM64_DB}-$TS.bak"
  # COPY_ONLY so these never disturb a real backup chain; CHECKSUM so a backup
  # taken from an emulated instance is at least self-verifying.
  if ERR=$(arm64_sql -Q "BACKUP DATABASE [$ARM64_DB] TO DISK='$F' WITH COPY_ONLY, INIT, CHECKSUM, COMPRESSION" 2>&1); then
    echo "[backup] $(date -Is) ok -> $F"
    # Prune with the shell inside the sql container. (xp_cmdshell does not exist
    # on SQL Server on Linux.)
    docker compose $C exec -T sql sh -c "ls -1t /backups/${ARM64_DB}-*.bak 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f" \
      || echo "[backup] $(date -Is) WARN: pruning old backups failed"
  else
    echo "[backup] $(date -Is) FAILED: $(printf '%s' "$ERR" | tr '\n' ' ' | cut -c1-300)"
  fi
  sleep "$INTERVAL"
done
