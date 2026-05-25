#!/bin/bash
set -eu

DEBUG=${DEBUG-false}
FQDN=$(hostname -f)
RELAY_DOMAINS=${RELAY_DOMAINS:-} # Empty to relay all emails
MYNETWORKS=${MYNETWORKS:-127.0.0.0/8 172.16.0.0/12 192.168.0.0/16 10.0.0.0/8}

# Helper to check boolean variables (handles literal quotes)
is_true() {
    local val=$(echo "${1:-false}" | sed 's/["'\'']//g' | tr '[:upper:]' '[:lower:]')
    [ "$val" = "true" ] || [ "$val" = "yes" ] || [ "$val" = "1" ]
}

# Configure Postfix basics
postconf -e myhostname="${FQDN}"
postconf -e relay_domains="${RELAY_DOMAINS}"
postconf -e smtpd_sasl_auth_enable=no
postconf -e "mynetworks= ${MYNETWORKS}"
postconf -# mydestination
postconf -F '*/*/chroot = n'
postconf -e "inet_protocols = ipv4"

# --- Dynamic Postfix Configuration via PCONF_ environment variables ---
echo "Checking for dynamic Postfix configuration (PCONF_)..."
# Use || true to prevent script exit if no matches found
for var in $(env | grep '^PCONF_' || true); do
    param_name=$(echo "$var" | cut -d'=' -f1 | sed 's/^PCONF_//')
    param_value=$(echo "$var" | cut -d'=' -f2-)
    echo "Setting $param_name = $param_value"
    postconf -e "$param_name = $param_value"
done

if is_true "${DEBUG}"; then
    sed -i 's/smtpd$/smtpd -v/g' /etc/postfix/master.cf
fi

# --- DKIM setup ---
if is_true "${DKIM_ENABLED:-false}"; then
    echo "Configuring DKIM for ${DKIM_DOMAIN}..."
    if [ ! -f /opt/__dkim_init ]; then
        DKIM_SELECTOR=${DKIM_SELECTOR:-default}
        DKIM_KEY_DIR="/etc/opendkim/keys/${DKIM_DOMAIN}"
        DKIM_KEY="${DKIM_KEY_DIR}/${DKIM_SELECTOR}.private"

        if [ ! -f "$DKIM_KEY" ]; then
            if is_true "${DKIM_AUTOGEN:-false}"; then
                echo "DKIM key not found, generating one for ${DKIM_DOMAIN}..."
                mkdir -p "$DKIM_KEY_DIR"
                opendkim-genkey -b 2048 -d "$DKIM_DOMAIN" -s "$DKIM_SELECTOR" -D "$DKIM_KEY_DIR"
                mv "${DKIM_KEY_DIR}/${DKIM_SELECTOR}.private" "$DKIM_KEY"
                echo "DKIM key generated at $DKIM_KEY"
                echo "Public key (DNS TXT record):"
                cat "${DKIM_KEY_DIR}/${DKIM_SELECTOR}.txt"
            else
                echo "Error! No DKIM key found at $DKIM_KEY and DKIM_AUTOGEN is not true" >&2
                exit 1
            fi
        fi

        mkdir -p /etc/opendkim
        echo "*@${DKIM_DOMAIN} ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}" >/etc/opendkim/SigningTable
        echo "${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN} ${DKIM_DOMAIN}:${DKIM_SELECTOR}:${DKIM_KEY}" >/etc/opendkim/KeyTable
        
        echo "Configuring OpenDKIM TrustedHosts..."
        # Add local networks to TrustedHosts
        echo "127.0.0.1" > /etc/opendkim/TrustedHosts
        echo "localhost" >> /etc/opendkim/TrustedHosts
        for net in ${MYNETWORKS}; do
            echo "$net" >>/etc/opendkim/TrustedHosts
        done

        [ -n "${DKIM_AUTHORIZED_HOSTS:-}" ] && echo "${DKIM_AUTHORIZED_HOSTS//,/$'\n'}" >>/etc/opendkim/TrustedHosts
        echo "*.${DKIM_DOMAIN}" >>/etc/opendkim/TrustedHosts

        echo "Ensuring DKIM key permissions..."
        if [ -f "$DKIM_KEY" ]; then
            chown opendkim:opendkim "$DKIM_KEY"
            chmod 600 "$DKIM_KEY"
        fi
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
    echo "Starting OpenDKIM..."
    opendkim -f -x /etc/opendkim.conf &
fi

# --- SMTP Relay Authentication ---
if is_true "${AUTH_ENABLED:-false}"; then
    echo "Configuring SMTP Relay Authentication..."
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
        postconf -e "smtp_sasl_security_options = noanonymous"
        postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
        postconf -e "smtp_use_tls = yes"
        postconf -e "smtp_tls_security_level = may"
        touch /opt/__auth_init
    fi
fi

QUEUE_DIRS="active bounce corrupt deferred defer flush hold incoming maildrop pid private saved trace public"

for dir in $QUEUE_DIRS; do
    mkdir -p /var/spool/postfix/$dir
done

# Fix ownership and permissions
chown root:root /var/spool/postfix
mkdir -p /var/log/mail
chown -R postfix:postfix /var/log/mail
chown -R postfix:postfix /var/spool/postfix/{active,bounce,corrupt,deferred,defer,flush,hold,incoming,pid,private,saved,trace}
chown postfix:postdrop /var/spool/postfix/{public,maildrop}
chmod 700 /var/spool/postfix/{active,bounce,corrupt,deferred,defer,flush,hold,incoming,pid,private,saved,trace,maildrop}
chmod 755 /var/spool/postfix/public

# Ensure pid directory owned by root
chown root:root /var/spool/postfix/pid
chmod 700 /var/spool/postfix/pid

# Start rsyslog
[ -f /var/run/rsyslogd.pid ] && rm -f /var/run/rsyslogd.pid
rsyslogd

# Start Postfix in foreground as the main process
echo "Starting Postfix..."
exec postfix start-fg
