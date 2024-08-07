#!/bin/bash -eu

DEBUG=${DEBUG-false}
# use the full qualified hostname to pass the fqdn check on the EHLO command
FQDN=$(hostname -f)
RELAY_DOMAINS= #Empty to relay all emails

postconf -e myhostname="${FQDN}"
postconf -e relay_domains=${RELAY_DOMAINS}
postconf -e smtpd_sasl_auth_enable=no
postconf -e "mynetworks= 127.0.0.0/8 172.16.0.0/12 192.0.0.0/8"
postconf -# mydestination
postconf -F '*/*/chroot = n'

postconf -x mydestination
[ "$DEBUG" == "true" ] && sed -i 's/smtpd$/smtpd -v/g' /etc/postfix/master.cf
# Enforce IPv4 
postconf -e "inet_protocols = ipv4"

if [ ${DKIM_ENABLED:-false} == "true" ]; then
    if [ ! -f /opt/__dkim_init ]; then
        [ -z "${DKIM_SELECTOR:-}" ] && DKIM_SELECTOR='default'
        if [ ! -f "/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private" ]; then
            echo "Error! No such private DKIM KEY found /etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private ! Aborting..."
            exit 1
        fi
        echo "Domain ${DKIM_DOMAIN}" >>/etc/opendkim.conf
        echo 'RequireSafeKeys False' >>/etc/opendkim.conf
        mkdir -p /etc/opendkim
        echo "*@${DKIM_DOMAIN} ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}" >>/etc/opendkim/SigningTable
        echo "${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN} ${DKIM_DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private" >>/etc/opendkim/KeyTable
        [ -z "${DKIM_AUTHORIZED_HOSTS:-}" ] || echo ${DKIM_AUTHORIZED_HOSTS} | sed 's/,/\n/g' | xargs -L 1 >>/etc/opendkim/TrustedHosts
        echo "*.${DKIM_DOMAIN}" >>/etc/opendkim/TrustedHosts
        chown opendkim:opendkim /etc/opendkim/keys -R
        [ -e /var/spool/postfix/opendkim ] || mkdir /var/spool/postfix/opendkim
        chown opendkim:postfix /var/spool/postfix/opendkim
        sed -i 's|local:/run/opendkim/opendkim.sock|local:/var/spool/postfix/opendkim/opendkim.sock|g' /etc/opendkim.conf
        # Milter configuration
        postconf -e "milter_default_action = accept"
        postconf -e "milter_protocol = 2"
        postconf -e "smtpd_milters = inet:localhost:8891"
        postconf -e "non_smtpd_milters = \$smtpd_milters"
        touch /opt/__dkim_init
    fi
    opendkim -fx /etc/opendkim.conf &
fi

if [ ${AUTH_ENABLED:-false} == "true" ]; then
    if [ -z "${RELAY_HOST:-}" ]; then 
        echo "Error! Relay Host must be provided"
        exit 1 
    fi
    if [ -z "${AUTH_USER:-}" ]; then 
        echo "Error! Username must be provided"
        exit 1 
    fi
    if [ ! -f /opt/__auth_init ]; then
        echo "${RELAY_HOST} ${AUTH_USER}:${AUTH_PASSWORD:-}" > /etc/postfix/sasl_passwd
        chmod 600 /etc/postfix/sasl_passwd
        postmap /etc/postfix/sasl_passwd
        postconf -e "relayhost = [${RELAY_HOST}]"
        # authentication
        postconf -e "smtpd_sasl_auth_enable = yes"
        postconf -e "smtp_sasl_auth_enable = yes"
        postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
        postconf -e "smtp_sasl_security_options ="
        postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
        postconf -e "smtp_use_tls = yes"
        touch /opt/__auth_init
    fi
fi

[ -f /var/run/rsyslogd.pid ] && rm -f /var/run/rsyslogd.pid
rsyslogd
postfix start

tail -F /dev/null
