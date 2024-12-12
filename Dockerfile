FROM alpine:3.21

ARG POSTFIX_UID=1000

RUN addgroup -g ${POSTFIX_UID} postfix
RUN adduser -u ${POSTFIX_UID} -G postfix -s /bin/false --disabled-password postfix

RUN apk update && \
    apk upgrade && \
    apk add --no-cache postfix rsyslog netcat-openbsd opendkim shadow bash && gpasswd -a postfix opendkim

RUN mkdir -p /var/spool/rsyslog && \
    chown postfix:postdrop /var/spool/rsyslog && \
    chmod 0755 /var/spool/rsyslog

COPY entrypoint.sh /
COPY rsyslog.conf /etc/
COPY opendkim.conf /etc/opendkim.conf

RUN chmod u+x entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD printf "EHLO healthcheck\n" | nc 127.0.0.1 25 | grep -qE "^220.*ESMTP Postfix"

ENTRYPOINT [ "/entrypoint.sh" ]

EXPOSE 25
