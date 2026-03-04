#!/bin/bash
set -eu

DEBUG=${DEBUG-false}
FQDN=$(hostname -f)
RELAY_DOMAINS=${RELAY_DOMAINS:-} # Empty to relay all emails

# --- Outbound throttling defaults (can be overridden via env) ---
SMTP_DEST_CONCURRENCY=${SMTP_DEST_CONCURRENCY:-2}
SMTP_DEST_RATE_DELAY=${SMTP_DEST_RATE_DELAY:-1s}
MINIMAL_BACKOFF_TIME=${MINIMAL_BACKOFF_TIME:-300s}
MAXIMAL_BACKOFF_TIME=${MAXIMAL_BACKOFF_TIME:-4000s}
DEFAULT_PROCESS_LIMIT=${DEFAULT_PROCESS_LIMIT:-50}

# Configure Postfix basics
postconf -e myhostname="${FQDN}"
postconf -e relay_domains="${RELAY_DOMAINS}"
postconf -e smtpd_sasl_auth_enable=no
postconf -e "mynetworks= 127.0.0.0/8 172.16.0.0/12 192.0.0.0/8"
postconf -# mydestination
postconf -F '*/*/chroot = n'
postconf -e "inet_protocols = ipv4"

[ "$DEBUG" = "true" ] && sed -i 's/smtpd$/smtpd -v/g' /etc/postfix/master.cf

# --- DKIM setup ---
if [ "${DKIM_ENABLED:-false}" = "true" ]; then
    if [ ! -f /opt/__dkim_init ]; then
        DKIM_SELECTOR=${DKIM_SELECTOR:-default}
        DKIM_KEY="/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private"
        if [ ! -f "$DKIM_KEY" ]; then
            echo "Error! No DKIM key found: $DKIM_KEY" >&2
            exit 1
        fi

        mkdir -p /etc/opendkim
        echo "*@${DKIM_DOMAIN} ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}" >/etc/opendkim/SigningTable
        echo "${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN} ${DKIM_DOMAIN}:${DKIM_SELECTOR}:${DKIM_KEY}" >/etc/opendkim/KeyTable
        [ -n "${DKIM_AUTHORIZED_HOSTS:-}" ] && echo "${DKIM_AUTHORIZED_HOSTS//,/$'\n'}" >>/etc/opendkim/TrustedHosts
        echo "*.${DKIM_DOMAIN}" >>/etc/opendkim/TrustedHosts

        chown -R opendkim:opendkim /etc/opendkim/keys
        mkdir -p /var/spool/postfix/opendkim
        chown opendkim:postfix /var/spool/postfix/opendkim

        # Use TCP socket
        sed -i 's|local:/run/opendkim/opendkim.sock|inet:8891|g' /etc/opendkim.conf

        # Postfix milter config
        postconf -e "milter_default_action = accept"
        postconf -e "milter_protocol = 2"
        postconf -e "smtpd_milters = inet:127.0.0.1:8891"
        postconf -e "non_smtpd_milters = \$smtpd_milters"

        touch /opt/__dkim_init
    fi
    opendkim -f -x /etc/opendkim.conf &
fi

# --- SMTP Relay Authentication ---
if [ "${AUTH_ENABLED:-false}" = "true" ]; then
    if [ -z "${RELAY_HOST:-}" ] || [ -z "${AUTH_USER:-}" ]; then
        echo "Error! RELAY_HOST and AUTH_USER must be provided for AUTH_ENABLED=true" >&2
        exit 1
    fi
    if [ ! -f /opt/__auth_init ]; then
        echo "[${RELAY_HOST}] ${AUTH_USER}:${AUTH_PASSWORD:-}" >/etc/postfix/sasl_passwd
        chmod 600 /etc/postfix/sasl_passwd
        postmap /etc/postfix/sasl_passwd
        postconf -e "relayhost = [${RELAY_HOST}]"
        postconf -e "smtp_sasl_auth_enable = yes"
        postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
        postconf -e "smtp_sasl_security_options ="
        postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
        postconf -e "smtp_use_tls = yes"
        touch /opt/__auth_init
    fi
fi

# --- Apply outbound throttling ---
postconf -e "smtp_destination_concurrency_limit = ${SMTP_DEST_CONCURRENCY}"
postconf -e "smtp_destination_rate_delay = ${SMTP_DEST_RATE_DELAY}"
postconf -e "minimal_backoff_time = ${MINIMAL_BACKOFF_TIME}"
postconf -e "maximal_backoff_time = ${MAXIMAL_BACKOFF_TIME}"
postconf -e "default_process_limit = ${DEFAULT_PROCESS_LIMIT}"

QUEUE_DIRS="active bounce corrupt deferred defer flush hold incoming maildrop pid private saved trace public"

for dir in $QUEUE_DIRS; do
    mkdir -p /var/spool/postfix/$dir
done

# Fix ownership and permissions
chown -R postfix:postfix /var/spool/postfix/{active,bounce,corrupt,deferred,defer,flush,hold,incoming,pid,private,saved,trace}
chown postfix:postdrop /var/spool/postfix/{public,maildrop}
chmod 700 /var/spool/postfix/{active,bounce,corrupt,deferred,defer,flush,hold,incoming,pid,private,saved,trace,maildrop}
chmod 755 /var/spool/postfix/public

# Ensure pid directory owned by root
chown root:root /var/spool/postfix/pid
chmod 700 /var/spool/postfix/pid

# Start rsyslog and Postfix
[ -f /var/run/rsyslogd.pid ] && rm -f /var/run/rsyslogd.pid
rsyslogd
postfix start-fg

# Keep container alive for logs
tail -F /dev/null
