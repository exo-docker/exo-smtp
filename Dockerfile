FROM alpine:3.23

LABEL org.opencontainers.image.title="exo-smtp" \
      org.opencontainers.image.description="Postfix SMTP relay with OpenDKIM, relay auth and TLS" \
      org.opencontainers.image.source="https://github.com/exo-docker/exo-smtp" \
      org.opencontainers.image.vendor="eXo Platform"

# Install necessary packages
RUN apk add --no-cache \
        bash \
        postfix \
        rsyslog \
        opendkim \
        opendkim-utils \
        netcat-openbsd \
        ca-certificates \
        openssl \
        tini \
        shadow \
    # Create postfix:opendkim group mapping
    && addgroup postfix opendkim \
    && mkdir -p /var/spool/rsyslog /var/log/mail /var/run/opendkim /etc/opendkim/keys /var/spool/postfix/opendkim /etc/rsyslog.d \
    && chown -R postfix:postfix /var/spool/rsyslog /var/log/mail \
    && chown -R opendkim:opendkim /var/run/opendkim /etc/opendkim/keys \
    && chown opendkim:postfix /var/spool/postfix/opendkim \
    # Change postfix UID/GID to 1000
    && usermod -u 1000 postfix \
    && groupmod -g 1000 postfix \
    && find /var /etc /usr /run -xdev -user 101 -exec chown -h 1000 {} \; \
    && find /var /etc /usr /run -xdev -group 101 -exec chgrp -h 1000 {} \; \
    # Change postdrop GID to 1003
    && groupmod -g 1003 postdrop \
    && find /var /etc /usr /run -xdev -group 103 -exec chgrp -h 1003 {} \; \
    # Fix setgid on Postfix binaries to remove warnings
    && chown root:postdrop /usr/sbin/postqueue /usr/sbin/postdrop \
    && chmod g+s /usr/sbin/postqueue /usr/sbin/postdrop \
    && apk del shadow

# Copy configuration files
COPY entrypoint.sh healthcheck.sh /
COPY rsyslog.conf /etc/rsyslog.conf
COPY opendkim.conf /etc/opendkim.conf

RUN chmod u+x /entrypoint.sh /healthcheck.sh

# Healthcheck: postfix, rsyslog and (when enabled) opendkim
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/healthcheck.sh"]

# tini reaps zombies and forwards signals
ENTRYPOINT [ "/sbin/tini", "--", "/entrypoint.sh" ]
EXPOSE 25
