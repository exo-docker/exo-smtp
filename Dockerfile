FROM ubuntu:22.04

ARG POSTFIX_UID=1000
ARG DEBIAN_FRONTEND=noninteractive

RUN useradd -u ${POSTFIX_UID} -s /bin/false postfix && apt-get update && apt-get install -y postfix rsyslog netcat opendkim && gpasswd -a postfix opendkim

COPY entrypoint.sh /
COPY rsyslog.conf /etc/

RUN chmod u+x entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD printf "EHLO healthcheck\n" | nc 127.0.0.1 25 | grep -qE "^220.*ESMTP Postfix"

ENTRYPOINT [ "/entrypoint.sh" ]

EXPOSE 25
