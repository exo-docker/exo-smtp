#!/bin/bash
# Healthy only if every enabled component is up.
nc -z 127.0.0.1 25 || { echo "postfix not listening on 25"; exit 1; }
pgrep rsyslogd >/dev/null || { echo "rsyslogd not running"; exit 1; }
if [ "${DKIM_ENABLED:-false}" = "true" ]; then
    nc -z 127.0.0.1 8891 || { echo "opendkim not listening on 8891"; exit 1; }
fi
