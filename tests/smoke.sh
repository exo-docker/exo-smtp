#!/bin/bash
# Smoke test: ./tests/smoke.sh [image]   (default: exo-smtp:test)
set -uo pipefail

IMAGE=${1:-exo-smtp:test}
NAME=exo-smtp-smoke
FAILED=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILED=1; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; }
trap cleanup EXIT

wait_healthy() {
    for _ in $(seq 1 40); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null)" = "healthy" ] && return 0
        sleep 2
    done
    return 1
}

# 1. Invalid configuration must be rejected with a clear message
cleanup
out=$(docker run --rm -e SMTP_TLS_SECURITY_LEVEL=bogus "$IMAGE" 2>&1) && fail "invalid TLS level accepted" || {
    grep -q "Invalid SMTP_TLS_SECURITY_LEVEL" <<<"$out" && pass "invalid TLS level rejected" || fail "bad error message: $out"
}
out=$(docker run --rm -e DKIM_ENABLED=true "$IMAGE" 2>&1) && fail "missing DKIM_DOMAIN accepted" || {
    grep -q "DKIM_DOMAIN must be provided" <<<"$out" && pass "missing DKIM_DOMAIN rejected" || fail "bad error message: $out"
}

# 2. Plain start: healthy, tuned settings applied, logs on stdout
docker run -d --name "$NAME" -e MYNETWORKS="127.0.0.0/8" -e MESSAGE_SIZE_LIMIT=5000000 "$IMAGE" >/dev/null
wait_healthy && pass "container healthy" || fail "container not healthy"
[ "$(docker exec "$NAME" postconf -h message_size_limit)" = "5000000" ] && pass "MESSAGE_SIZE_LIMIT applied" || fail "MESSAGE_SIZE_LIMIT"
[ "$(docker exec "$NAME" postconf -h smtp_tls_security_level)" = "may" ] && pass "default TLS level is may" || fail "default TLS level"
[ "$(docker exec "$NAME" postconf -h mynetworks)" = "127.0.0.0/8" ] && pass "MYNETWORKS applied" || fail "MYNETWORKS"

# 3. Graceful stop (tini + trap) must not hit the 10s kill timeout
start=$(date +%s)
docker stop "$NAME" >/dev/null
[ $(($(date +%s) - start)) -lt 9 ] && pass "graceful shutdown" || fail "slow shutdown (SIGKILL?)"
cleanup

# 4. DKIM with generated key + auth => TLS defaults to encrypt; message gets signed
docker run -d --name "$NAME" \
    -e DKIM_ENABLED=true -e DKIM_DOMAIN=example.test -e DKIM_AUTOGENERATE=true \
    -e AUTH_ENABLED=true -e RELAY_HOST=relay.invalid -e AUTH_USER=u -e AUTH_PASSWORD=p \
    "$IMAGE" >/dev/null
wait_healthy && pass "DKIM container healthy (opendkim up)" || fail "DKIM container not healthy"
[ "$(docker exec "$NAME" postconf -h smtp_tls_security_level)" = "encrypt" ] && pass "TLS defaults to encrypt with auth" || fail "auth TLS default"

docker exec "$NAME" bash -c '
exec 3<>/dev/tcp/127.0.0.1/25
# read a (possibly multi-line) SMTP reply, keep the last line
reply() { while IFS= read -r -u 3 l; do [[ $l =~ ^[0-9]{3}- ]] || break; done; echo "$l" | tr -d "\r"; }
send() { printf "%s\r\n" "$1" >&3; }
reply >/dev/null
send "EHLO test"; reply >/dev/null
send "MAIL FROM:<a@example.test>"; reply >/dev/null
send "RCPT TO:<b@example.org>"; reply >/dev/null
send "DATA"; reply >/dev/null
printf "Subject: smoke\r\n\r\nhello\r\n.\r\n" >&3
reply
send "QUIT"' | grep -q "^250 .*queued" && pass "message accepted" || fail "message not accepted"
sleep 2
if docker exec "$NAME" bash -c 'for id in $(postqueue -p | awk "/^[0-9A-F]+[*!]? /{print \$1}" | tr -d "*!"); do postcat -q "$id"; done' | grep -q "^DKIM-Signature:"; then
    pass "message DKIM-signed"
else
    fail "no DKIM signature on queued message"
    docker logs "$NAME" 2>&1 | tail -40
fi

exit $FAILED
