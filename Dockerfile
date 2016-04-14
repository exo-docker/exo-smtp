#FROM alpine:3.3
FROM debian:8.0

RUN apt-get update && apt-get install -y postfix rsyslog 

COPY entrypoint.sh /

RUN chmod u+x entrypoint.sh

ENTRYPOINT /entrypoint.sh

EXPOSE 25

VOLUME [ "/var/spool/postfix" ]
