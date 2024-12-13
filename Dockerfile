FROM ubuntu:24.04

ARG POSTFIX_UID=1000
ARG DEBIAN_FRONTEND=noninteractive

RUN REPLACED_USER_ID=$(getent passwd ${POSTFIX_UID} | cut -d ':' -f 1) && \
    usermod -u 2005 "$REPLACED_USER_ID" && \
    groupmod -g 2005 "$REPLACED_USER_ID"

RUN useradd -u ${POSTFIX_UID} -s /bin/false postfix && apt-get update && apt-get install -y postfix rsyslog netcat-openbsd opendkim && gpasswd -a postfix opendkim

RUN mkdir -p /var/spool/rsyslog

COPY entrypoint.sh /
COPY rsyslog.conf /etc/
COPY opendkim.conf /etc/opendkim.conf

RUN chmod u+x entrypoint.sh

RUN mkdir -p /var/log && touch /var/log/syslog && \
    chown syslog:adm /var/log/syslog && chmod 664 /var/log/syslog

RUN touch /var/log/mail.log && chown syslog:adm /var/log/mail.log && chmod 664 /var/log/mail.log

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD printf "EHLO healthcheck\n" | nc 127.0.0.1 25 | grep -qE "^220.*ESMTP Postfix"

ENTRYPOINT [ "/entrypoint.sh" ]

EXPOSE 25
