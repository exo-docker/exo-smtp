#!/bin/bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }
die() {
    echo "Error! $*" >&2
    exit 1
}
is_true() { [ "${1:-false}" = "true" ]; }

DEBUG=${DEBUG:-false}
FQDN=${MYHOSTNAME:-$(hostname -f 2>/dev/null || hostname)}
# Domains we relay mail *to* (in addition to what mynetworks may send). Empty = no extra relay domains.
# Who may relay *through* us is controlled by MYNETWORKS, not by this variable.
RELAY_DOMAINS=${RELAY_DOMAINS:-}
# Clients allowed to relay through this container (private ranges only by default)
MYNETWORKS=${MYNETWORKS:-127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}

# --- Postfix basics ---
postconf -e "myhostname = ${FQDN}"
postconf -e "relay_domains = ${RELAY_DOMAINS}"
postconf -e "smtpd_sasl_auth_enable = no"
postconf -e "mynetworks = ${MYNETWORKS}"
postconf -# mydestination
postconf -F '*/*/chroot = n'
postconf -e "inet_protocols = ipv4"
postconf -e "message_size_limit = ${MESSAGE_SIZE_LIMIT:-10240000}"
postconf -e "maximal_queue_lifetime = ${MAX_QUEUE_LIFETIME:-5d}"
postconf -e "smtpd_banner = ${SMTPD_BANNER:-\$myhostname ESMTP}"
postconf -e "smtp_helo_name = ${SMTP_HELO_NAME:-\$myhostname}"

if is_true "$DEBUG"; then
    sed -i 's/smtpd$/smtpd -v/' /etc/postfix/master.cf
fi

# --- Logging ---
LOG_FILE_MODE=${LOG_FILE_MODE:-0640}
[[ "$LOG_FILE_MODE" =~ ^0[0-7]{3}$ ]] || die "Invalid LOG_FILE_MODE: ${LOG_FILE_MODE} (octal, e.g. 0640)"
sed -i "s/^\$FileCreateMode.*/\$FileCreateMode ${LOG_FILE_MODE}/" /etc/rsyslog.conf
mkdir -p /etc/rsyslog.d
if is_true "${LOG_TO_STDOUT:-true}"; then
    echo 'mail.*    /dev/stdout' >/etc/rsyslog.d/10-stdout.conf
else
    rm -f /etc/rsyslog.d/10-stdout.conf
fi

# --- Sender override (e.g. relays requiring a fixed From such as SES / Office365) ---
if [ -n "${SMTP_FROM:-}" ]; then
    echo "/^.+\$/ ${SMTP_FROM}" >/etc/postfix/sender_canonical
    postconf -e "sender_canonical_maps = regexp:/etc/postfix/sender_canonical"
    postconf -e "sender_canonical_classes = envelope_sender, header_sender"
else
    postconf -e "sender_canonical_maps ="
fi

# --- DKIM setup (one or more comma separated domains) ---
if is_true "${DKIM_ENABLED:-false}"; then
    [ -n "${DKIM_DOMAIN:-}" ] || die "DKIM_DOMAIN must be provided when DKIM_ENABLED=true"
    DKIM_SELECTOR=${DKIM_SELECTOR:-default}

    mkdir -p /etc/opendkim/keys
    : >/etc/opendkim/SigningTable
    : >/etc/opendkim/KeyTable
    printf '127.0.0.1\nlocalhost\n' >/etc/opendkim/TrustedHosts
    [ -n "${DKIM_AUTHORIZED_HOSTS:-}" ] && echo "${DKIM_AUTHORIZED_HOSTS//,/$'\n'}" >>/etc/opendkim/TrustedHosts

    IFS=',' read -ra DKIM_DOMAINS <<<"${DKIM_DOMAIN}"
    for domain in "${DKIM_DOMAINS[@]}"; do
        domain=${domain//[[:space:]]/}
        [ -n "$domain" ] || continue
        key_dir="/etc/opendkim/keys/${domain}"
        key="${key_dir}/${DKIM_SELECTOR}.private"

        if [ ! -f "$key" ]; then
            if is_true "${DKIM_AUTOGENERATE:-false}"; then
                log "Generating DKIM key for ${domain} (selector ${DKIM_SELECTOR})"
                mkdir -p "$key_dir"
                opendkim-genkey -b 2048 -d "$domain" -s "$DKIM_SELECTOR" -D "$key_dir"
                log "Publish this DNS TXT record:"
                cat "${key_dir}/${DKIM_SELECTOR}.txt"
            else
                die "No DKIM key found: $key (mount one, or set DKIM_AUTOGENERATE=true)"
            fi
        fi

        echo "*@${domain} ${DKIM_SELECTOR}._domainkey.${domain}" >>/etc/opendkim/SigningTable
        echo "${DKIM_SELECTOR}._domainkey.${domain} ${domain}:${DKIM_SELECTOR}:${key}" >>/etc/opendkim/KeyTable
        echo "*.${domain}" >>/etc/opendkim/TrustedHosts
    done

    # Keys may be on a read-only mount: ownership is best effort
    chown -R opendkim:opendkim /etc/opendkim/keys 2>/dev/null || log "Warning: could not chown DKIM keys (read-only mount?)"

    postconf -e "milter_default_action = accept"
    postconf -e "milter_protocol = 2"
    postconf -e "smtpd_milters = inet:127.0.0.1:8891"
    postconf -e "non_smtpd_milters = \$smtpd_milters"
else
    postconf -e "smtpd_milters ="
    postconf -e "non_smtpd_milters ="
fi

# --- SMTP Relay Authentication ---
if is_true "${AUTH_ENABLED:-false}"; then
    [ -n "${RELAY_HOST:-}" ] && [ -n "${AUTH_USER:-}" ] || die "RELAY_HOST and AUTH_USER must be provided for AUTH_ENABLED=true"
    [ -n "${AUTH_PASSWORD:-}" ] || log "Warning: AUTH_PASSWORD is empty"
    RELAY_TARGET="[${RELAY_HOST}]${RELAY_PORT:+:${RELAY_PORT}}"
    echo "${RELAY_TARGET} ${AUTH_USER}:${AUTH_PASSWORD:-}" >/etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd
    postconf -e "relayhost = ${RELAY_TARGET}"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_sasl_security_options ="
else
    postconf -e "smtp_sasl_auth_enable = no"
fi

# --- Outbound TLS ---
# none: no TLS | may: opportunistic | encrypt: mandatory | verify/secure: mandatory + certificate check
# Defaults to "encrypt" when relay authentication is enabled (credentials must not travel in clear text).
if is_true "${AUTH_ENABLED:-false}"; then
    DEFAULT_TLS_LEVEL=encrypt
else
    DEFAULT_TLS_LEVEL=may
fi
SMTP_TLS_SECURITY_LEVEL=${SMTP_TLS_SECURITY_LEVEL:-$DEFAULT_TLS_LEVEL}
case "$SMTP_TLS_SECURITY_LEVEL" in
    none) postconf -e "smtp_tls_security_level =" ;;
    may | encrypt | verify | secure) postconf -e "smtp_tls_security_level = ${SMTP_TLS_SECURITY_LEVEL}" ;;
    *) die "Invalid SMTP_TLS_SECURITY_LEVEL: ${SMTP_TLS_SECURITY_LEVEL} (none|may|encrypt|verify|secure)" ;;
esac
postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
postconf -e "smtp_tls_loglevel = ${SMTP_TLS_LOGLEVEL:-1}"

# --- Inbound TLS (optional: mount a certificate and key) ---
if [ -n "${SMTPD_TLS_CERT_FILE:-}" ] || [ -n "${SMTPD_TLS_KEY_FILE:-}" ]; then
    [ -f "${SMTPD_TLS_CERT_FILE:-}" ] || die "SMTPD_TLS_CERT_FILE not found: ${SMTPD_TLS_CERT_FILE:-<unset>}"
    [ -f "${SMTPD_TLS_KEY_FILE:-}" ] || die "SMTPD_TLS_KEY_FILE not found: ${SMTPD_TLS_KEY_FILE:-<unset>}"
    postconf -e "smtpd_tls_cert_file = ${SMTPD_TLS_CERT_FILE}"
    postconf -e "smtpd_tls_key_file = ${SMTPD_TLS_KEY_FILE}"
    postconf -e "smtpd_tls_security_level = ${SMTPD_TLS_SECURITY_LEVEL:-may}"
    postconf -e "smtpd_tls_loglevel = ${SMTP_TLS_LOGLEVEL:-1}"
else
    postconf -e "smtpd_tls_security_level ="
fi

postalias /etc/postfix/aliases 2>/dev/null || true

# --- Queue directories ---
QUEUE_DIRS="active bounce corrupt deferred defer flush hold incoming maildrop pid private saved trace public"

for dir in $QUEUE_DIRS; do
    mkdir -p "/var/spool/postfix/$dir"
done

chown -R postfix:postfix /var/spool/postfix/{active,bounce,corrupt,deferred,defer,flush,hold,incoming,pid,private,saved,trace}
chown postfix:postdrop /var/spool/postfix/{public,maildrop}
chmod 700 /var/spool/postfix/{active,bounce,corrupt,deferred,defer,flush,hold,incoming,pid,private,saved,trace,maildrop}
chmod 755 /var/spool/postfix/public

# Ensure pid directory owned by root
chown root:root /var/spool/postfix/pid
chmod 700 /var/spool/postfix/pid

# --- Start services and supervise them ---
# If any of them exits the container stops, so the restart policy / orchestrator can act.
pids=()

rm -f /var/run/rsyslogd.pid
rsyslogd -n &
pids+=($!)
for _ in $(seq 1 50); do
    [ -S /dev/log ] && break
    sleep 0.1
done

if is_true "${DKIM_ENABLED:-false}"; then
    opendkim -f -x /etc/opendkim.conf &
    pids+=($!)
fi

postfix start-fg &
pids+=($!)

stop_all() {
    kill -TERM "${pids[@]}" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap 'log "Signal received, stopping"; stop_all; exit 0' TERM INT

wait -n "${pids[@]}" || true
log "A service exited unexpectedly, stopping container" >&2
stop_all
exit 1
