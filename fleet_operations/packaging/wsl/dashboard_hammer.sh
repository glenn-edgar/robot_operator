#!/bin/bash
# dashboard_hammer.sh — simulate sustained dashboard polling at higher rate
# than a human browser to compress validation time.
#
# Hits the same endpoints the dashboard hits, in a tight loop with a small
# sleep. Tracks counts + first non-200. Quits on first error.
set -u

HOST=${HOST:-127.0.0.1}
PORT=${PORT:-8080}
DELAY=${DELAY:-0.2}      # seconds between cycles, 5 calls per cycle ≈ 25 req/s

ok=0
err=0
start=$(date +%s)

echo "==> dashboard_hammer.sh: hitting http://$HOST:$PORT at ~$(awk -v d="$DELAY" 'BEGIN{printf "%.1f",5/d}') req/s"
echo "==> ctrl-c to stop"

trap 'echo; echo "TOTAL ok=$ok err=$err elapsed=$(($(date +%s)-start))s"; exit 0' INT

while :; do
    # Every path here triggers at least one zenoh-rpc call through the
    # persistence client — that's the surface we're stress-testing.
    for path in \
        "/api/robots" \
        "/api/robots/farm_soil/lacima01/leaves" \
        "/api/robots/rancho_water/main/leaves" \
        "/api/robots/farm_soil/lacima01/latest?path=heartbeat" \
        "/api/robots/rancho_water/main/latest?path=heartbeat" \
        ; do
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://$HOST:$PORT$path")
        if [ "$code" = "200" ]; then
            ok=$((ok+1))
        else
            err=$((err+1))
            echo "$(date -Iseconds) NON-200 $code on $path"
        fi
    done
    if [ $(( (ok+err) % 500 )) = 0 ] && [ $((ok+err)) -gt 0 ]; then
        echo "$(date -Iseconds) progress: ok=$ok err=$err"
    fi
    sleep "$DELAY"
done
