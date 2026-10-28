#!/usr/bin/env bash
# Host-side recovery for the frontend only. Install/enable separately after testing.
set -Eeuo pipefail
umask 077

project="${WATCHDOG_PROJECT:-clarin-pl-dspace}"
service="${WATCHDOG_SERVICE:-dspace-angular}"
state_dir="${WATCHDOG_STATE_DIR:-/var/lib/clarin-dspace-watchdog}"
mkdir -p -- "$state_dir"
exec 9>"$state_dir/lock"
flock -n 9 || exit 0

mapfile -t containers < <(timeout 5 docker ps --quiet \
  --filter "label=com.docker.compose.project=$project" \
  --filter "label=com.docker.compose.service=$service")
if (( ${#containers[@]} != 1 )); then
  echo 'Frontend watchdog: expected exactly one running frontend; no action' >&2
  exit 1
fi
container="${containers[0]}"
status="$(timeout 5 docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container")"
[[ "$status" == unhealthy ]] || exit 0

# Refuse to act on old probes tied to backend readiness: a backend outage must
# never cause repeated frontend restarts.
probe="$(timeout 5 docker inspect --format '{{json .Config.Healthcheck.Test}}' "$container")"
if [[ "$probe" != *'/app/live'* ]]; then
  echo 'Frontend watchdog: dedicated /app/live probe required; no action' >&2
  exit 1
fi
if timeout 5 docker exec "$container" wget -T 3 -qO- http://127.0.0.1:4000/app/live >/dev/null 2>&1; then
  exit 0
fi

now="$(date +%s)"
history="$state_dir/restarts"
touch "$history"
awk -v cutoff="$((now - 1800))" '$1 ~ /^[0-9]+$/ && $1 > cutoff {print $1}' "$history" >"$history.next"
mv "$history.next" "$history"
mapfile -t restarts <"$history"
if (( ${#restarts[@]} >= 3 )); then
  echo 'ALERT: frontend restart budget exhausted (3 per 30 minutes); operator intervention required' >&2
  exit 1
fi
if (( ${#restarts[@]} > 0 && now - restarts[-1] < 90 )); then
  exit 0
fi
# Count attempts too, so a failing docker restart cannot create a restart loop.
printf '%s\n' "$now" >>"$history"
echo "ALERT: restarting unhealthy frontend $container; other services are untouched" >&2
timeout 25 docker restart --time 10 "$container"
