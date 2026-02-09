FROM alpine:3.23

# Install necessary packages
RUN apk add --no-cache \
        bash \
        postfix \
        rsyslog \
        opendkim \
        netcat-openbsd \
        ca-certificates \
        openssl \
        shadow \
    # Create postfix:opendkim group mapping
    && addgroup postfix opendkim \
    && mkdir -p /var/spool/rsyslog /var/log/mail /var/run/opendkim /etc/opendkim/keys /var/spool/postfix/opendkim \
    && chown -R postfix:postfix /var/spool/rsyslog /var/log/mail \
    && chown -R opendkim:opendkim /var/run/opendkim /etc/opendkim/keys \
    && chown opendkim:postfix /var/spool/postfix/opendkim \
    # Change postfix UID/GID to 1000
    && usermod -u 1000 postfix \
    && groupmod -g 1000 postfix \
    && find / -user 101 -exec chown -h 1000 {} \; \
    && find / -group 101 -exec chgrp -h 1000 {} \; \
    # Change postdrop GID to 1003
    && groupmod -g 1003 postdrop \
    && find / -group 103 -exec chgrp -h 1003 {} \; \
    # Fix setgid on Postfix binaries to remove warnings
    && chown root:postdrop /usr/sbin/postqueue /usr/sbin/postdrop \
    && chmod g+s /usr/sbin/postqueue /usr/sbin/postdrop \
    && apk del shadow

# Copy configuration files
COPY entrypoint.sh /
COPY rsyslog.conf /etc/rsyslog.conf
COPY opendkim.conf /etc/opendkim.conf

RUN chmod u+x /entrypoint.sh

# Healthcheck for Postfix
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD printf "EHLO healthcheck\n" | nc 127.0.0.1 25 | grep -qE "^220.*ESMTP Postfix"

ENTRYPOINT [ "/entrypoint.sh" ]
EXPOSE 25
