FROM alpine:3.22

RUN apk add --no-cache \
      postfix \
      cyrus-sasl \
      cyrus-sasl-login \
      ca-certificates \
      tini \
      tzdata \
 && mkdir -p /etc/sasl2

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

# 587 = submission (STARTTLS required), 465 = submissions (implicit TLS)
EXPOSE 587 465

VOLUME ["/var/spool/postfix"]

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
