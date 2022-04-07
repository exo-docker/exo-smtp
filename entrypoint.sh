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
    [ -z "${DKIM_SELECTOR:-}" ] && DKIM_SELECTOR='default'
    if [ ! -f "/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private" ]; then
        echo "Error! No such private DKIM KEY found /etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private ! Aborting..."
        exit 1
    fi
    sed -i 's/#Mode v/Mode sv/g' /etc/opendkim.conf

    cat >>/etc/opendkim.conf <<EOL
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
EOL

    echo "Domain ${DKIM_DOMAIN}" >>/etc/opendkim.conf
    echo 'RequireSafeKeys False' >>/etc/opendkim.conf
    mkdir -p /etc/opendkim
    echo "*@${DKIM_DOMAIN} ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}" >>/etc/opendkim/SigningTable
    echo "${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN} ${DKIM_DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private" >>/etc/opendkim/KeyTable
    echo "*.${DKIM_DOMAIN}" >>/etc/opendkim/TrustedHosts
    chown opendkim:opendkim /etc/opendkim/keys -R
    mkdir /var/spool/postfix/opendkim
    chown opendkim:postfix /var/spool/postfix/opendkim
    sed -i 's|local:/run/opendkim/opendkim.sock|local:/var/spool/postfix/opendkim/opendkim.sock|g' /etc/opendkim.conf
    cat >>/etc/postfix/main.cf <<EOL
# Milter configuration
milter_default_action = accept
milter_protocol = 6
smtpd_milters = local:opendkim/opendkim.sock
non_smtpd_milters = \$smtpd_milters
EOL
fi
rsyslogd
postfix start

tail -F /dev/null
