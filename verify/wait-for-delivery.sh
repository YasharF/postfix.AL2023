#!/bin/bash
# Wait for a message carrying a given marker to land in a Maildir.
#
#   wait-for-delivery.sh /root/Maildir plain-smtp
#
# Postfix accepting a message and Postfix delivering it are different events,
# so the SMTP check alone proves nothing about local delivery. This polls
# rather than sleeping a fixed amount: delivery is usually immediate, but the
# queue manager can take a moment on a loaded runner.

set -u

DIR=${1:?usage: wait-for-delivery.sh <maildir> <marker>}
MARKER=${2:?usage: wait-for-delivery.sh <maildir> <marker>}

for _ in $(seq 1 60); do
    if grep -rqs "marker: $MARKER" "$DIR/new" "$DIR/cur"; then
        echo "delivered: $MARKER"
        exit 0
    fi
    sleep 1
done

echo "no message carrying 'marker: $MARKER' reached $DIR after 60s"
ls -lR "$DIR" 2>&1 || echo "$DIR does not exist"
tail -50 /var/log/maillog 2>&1 || true
exit 1
