#!/usr/bin/env bash
# Unattended stability harness for the emulated arm64 stack.
#
#   scripts/arm64-soak.sh [--interval 60] [--hours 12] [--log FILE]
#
# Answers the only question that matters for "is this usable": how long does it
# stay up, and what dies first. Polls BC and SQL on an interval, timestamps every
# result, and keeps going after a failure so you learn the failure *pattern*
# rather than just the first event.
#
# Why this exists: the docker healthcheck cannot be trusted here. It tests for the
# /tmp/bc-ready file, which outlives the database — a container reported "healthy"
# for an hour while every request hung because SQL had aborted underneath it.
# This harness issues real queries against both tiers instead.
#
# Output is one CSV line per poll, so you can chart it or just tail it:
#   ts,elapsed_s,sql_state,bc_state,sql_query_ms,bc_api_ms,bc_http,note
set -uo pipefail
# Disable history expansion: this script contains Passw0rd123!} and an interactive
# or sourced shell expands `!}` as a history event ("bash: !}: event not found"),
# which aborts the assignment and leaves every sqlcmd in here silently
# unauthenticated -- observed as a bogus "no backup found".
set +H
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

INTERVAL=60; HOURS=12; LOG=/tmp/arm64-soak-$(date +%Y%m%d-%H%M%S).csv
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --hours) HOURS="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

. "$(dirname "${BASH_SOURCE[0]}")/_arm64-compose.sh"
COMPOSE="docker compose $(arm64_compose_files)"
AUTH="${BC_SERVER_USERNAME:-BCRUNNER}:${BC_SERVER_PASSWORD:-Admin123!}"
SA="${SA_PASSWORD:-Passw0rd123!}"
DEADLINE=$(( $(date +%s) + HOURS * 3600 ))
START=$(date +%s)

echo "ts,elapsed_s,sql_state,bc_state,sql_query_ms,bc_api_ms,bc_http,web_http,restarts,note" | tee "$LOG"

first_fail_reported=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  NOW=$(date +%s); ELAPSED=$(( NOW - START ))
  SQL_STATE=$($COMPOSE ps -a --format '{{.Service}}:{{.State}}' 2>/dev/null | grep '^sql:' | cut -d: -f2)
  BC_STATE=$($COMPOSE ps -a --format '{{.Service}}:{{.State}}' 2>/dev/null | grep '^bc:' | cut -d: -f2)

  # SQL: a real query, not a healthcheck
  t0=$(date +%s%N)
  if $COMPOSE exec -T sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA" -C -No \
       -Q "SELECT COUNT(*) FROM sys.databases" >/dev/null 2>&1; then
    SQL_MS=$(( ( $(date +%s%N) - t0 ) / 1000000 ))
  else
    SQL_MS=-1
  fi

  # BC: a real API call that requires Base Application to be mounted
  t0=$(date +%s%N)
  BC_HTTP=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" --max-time 60 \
      "http://localhost:${BC_API_PORT:-7052}/BC/api/v2.0/companies" 2>/dev/null)
  BC_MS=$(( ( $(date +%s%N) - t0 ) / 1000000 ))

  # web client (the image's own Kestrel host) — follow the sign-in redirect
  WEB_HTTP=$(curl -s -L -o /dev/null -w '%{http_code}' --max-time 45 \
      "http://localhost:${BC_WEBCLIENT_PORT:-8080}/" 2>/dev/null)
  RESTARTS=$($COMPOSE ps -aq bc 2>/dev/null | head -1 | xargs -r docker inspect --format '{{.RestartCount}}' 2>/dev/null)

  NOTE=""
  if [ "$SQL_MS" = "-1" ] || [ "$BC_HTTP" != "200" ] || [ "$WEB_HTTP" != "200" ]; then
    NOTE="DEGRADED"
    if [ "$first_fail_reported" = 0 ]; then
      NOTE="FIRST-FAILURE after ${ELAPSED}s"
      first_fail_reported=1
      # capture the evidence once, while it is fresh
      $COMPOSE logs --no-color sql 2>/dev/null | tail -40 > "${LOG%.csv}-sql-crash.log"
      $COMPOSE logs --no-color bc  2>/dev/null | tail -60 > "${LOG%.csv}-bc-crash.log"
    fi
  fi

  echo "$(date -Is),$ELAPSED,${SQL_STATE:-?},${BC_STATE:-?},$SQL_MS,$BC_MS,${BC_HTTP:-000},${WEB_HTTP:-000},${RESTARTS:-0},$NOTE" | tee -a "$LOG"
  sleep "$INTERVAL"
done

echo "# soak finished after $(( $(date +%s) - START ))s; log: $LOG" | tee -a "$LOG"
awk -F, 'NR>1 {n++; if($7=="200") api++; if($8=="200") web++; if($5!=-1) sql++}
  END {printf "# polls=%d  sql_ok=%d (%.1f%%)  api_ok=%d (%.1f%%)  web_ok=%d (%.1f%%)\n", n, sql, (n?100*sql/n:0), api, (n?100*api/n:0), web, (n?100*web/n:0)}' "$LOG" | tee -a "$LOG"
awk -F, 'NR>1 && $10 ~ /FIRST-FAILURE/ {print "# " $10; f=1} END {if(!f) print "# no failures observed"}' "$LOG" | tee -a "$LOG"
