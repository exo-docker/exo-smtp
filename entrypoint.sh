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

if [ ${DKIM_ENABLED:-false} == "true" ]; then
    if [ ! -f /opt/__dkim_init ]; then
        [ -z "${DKIM_SELECTOR:-}" ] && DKIM_SELECTOR='default'
        if [ ! -f "/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private" ]; then
            echo "Error! No such private DKIM KEY found /etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private ! Aborting..."
            exit 1
        fi
        cat >>/etc/opendkim.conf <<EOL
Canonicalization   simple
Mode               sv
SubDomains         no
AutoRestart         yes
AutoRestartRate     10/1M
Background          yes
DNSTimeout          5
SignatureAlgorithm  rsa-sha256
Socket inet:8891
#OpenDKIM user
# Remember to add user postfix to group opendkim
UserID             opendkim
# Map domains in From addresses to keys used to sign messages
KeyTable           refile:/etc/opendkim/KeyTable
SigningTable       refile:/etc/opendkim/SigningTable
# Hosts to ignore when verifying signatures
ExternalIgnoreList  /etc/opendkim/TrustedHosts
# A set of internal hosts whose mail should be signed
InternalHosts       /etc/opendkim/TrustedHosts
LogWhy                  yes
Syslog                  yes
SyslogSuccess           yes
EOL

        echo "Domain ${DKIM_DOMAIN}" >>/etc/opendkim.conf
        echo 'RequireSafeKeys False' >>/etc/opendkim.conf
        mkdir -p /etc/opendkim
        echo "*@${DKIM_DOMAIN} ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}" >>/etc/opendkim/SigningTable
        echo "${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN} ${DKIM_DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private" >>/etc/opendkim/KeyTable
        echo "0.0.0.0" >>/etc/opendkim/TrustedHosts
        echo "*.${DKIM_DOMAIN}" >>/etc/opendkim/TrustedHosts
        chown opendkim:opendkim /etc/opendkim/keys -R
        [ -e /var/spool/postfix/opendkim ] || mkdir /var/spool/postfix/opendkim
        chown opendkim:postfix /var/spool/postfix/opendkim
        sed -i 's|local:/run/opendkim/opendkim.sock|local:/var/spool/postfix/opendkim/opendkim.sock|g' /etc/opendkim.conf
        cat >>/etc/postfix/main.cf <<EOL
# Milter configuration
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:localhost:8891
non_smtpd_milters = \$smtpd_milters
EOL
        touch /opt/__dkim_init
    fi
fi

opendkim -fx /etc/opendkim.conf &
rsyslogd
postfix start

tail -F /dev/null
