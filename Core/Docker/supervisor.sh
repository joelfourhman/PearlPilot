#!/bin/sh
# A dead Windows controller must not leave an unattended miner behind.
# The worker refreshes this lease only while current policy permits mining.
set -u
touch /tmp/pearlpilot.lease
/opt/wildrig/wildrig-multi "$@" &
miner=$!
guard=''
cleanup() {
    if [ -n "$guard" ]; then kill "$guard" 2>/dev/null || true; wait "$guard" 2>/dev/null || true; fi
}
stop() {
    kill -TERM "$miner" 2>/dev/null || true
    wait "$miner"
    exit $?
}
trap cleanup EXIT
trap stop TERM INT
(
    while kill -0 "$miner" 2>/dev/null; do
        sleep 2
        now=$(date +%s)
        lease=$(stat -c %Y /tmp/pearlpilot.lease 2>/dev/null || echo 0)
        if [ "$((now - lease))" -gt 30 ]; then
            echo 'PearlPilot controller lease expired; stopping mining.' >&2
            kill -TERM "$miner" 2>/dev/null || true
            sleep 5
            kill -KILL "$miner" 2>/dev/null || true
            exit
        fi
    done
) &
guard=$!
wait "$miner"
exit $?
