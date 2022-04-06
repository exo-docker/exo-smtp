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

if [ ${DKIM_ENABLED} == "true" ]; then
    [ -z "${DKIM_SELECTOR:-}" ] && DKIM_SELECTOR='default'
    if [ ! -f "/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private" ]; then 
       echo "Error! No such private DKIM KEY found /etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private ! Aborting..."
       exit 1
    fi
    sed -i 's/Mode v/Mode sv/g' /etc/opendkim.conf
    sed -i -e 's/##Keyfile/Keyfile/g' \
        -e 's/##KeyTable/KeyTable/g' \
        -e 's/##SigningTable/SigningTable/g' \
        -e 's/##ExternalIgnoreList/ExternalIgnoreList/g' \
        -e 's/##InternalHosts/InternalHosts/g' /etc/opendkim.conf
    echo "Domain ${DKIM_DOMAIN}" >> /etc/opendkim.conf
    echo 'RequireSafeKeys False' >> /etc/opendkim.conf
    echo "*@${DKIM_DOMAIN} ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}" >> /etc/opendkim/SigningTable
    echo "${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN} ${DKIM_DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private" >> /etc/opendkim/KeyTable
    echo "*.${DKIM_DOMAIN}" >> /etc/opendkim/TrustedHosts
    chown opendkim:opendkim /etc/opendkim/keys -R 
fi

rsyslogd
postfix start

tail -F /dev/null
