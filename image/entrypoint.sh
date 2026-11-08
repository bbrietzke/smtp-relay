#!/bin/sh
# Postfix authenticated, TLS-only relay to an upstream smarthost.
#
# Required env:
#   RELAY_HOST         upstream host, e.g. smtp.fastmail.com
# Optional env:
#   RELAY_PORT         upstream port (default 587)
#   RELAY_USER         upstream SASL username
#   RELAY_PASSWORD     upstream SASL password
#   RELAY_TLS_WRAPPER  "yes" if the upstream port is implicit TLS (465)
#   MAIL_HOSTNAME      HELO/banner name (default: hostname -f)
#   SASL_REALM         realm for client usernames without "@" (default MAIL_HOSTNAME)
#   MYNETWORKS         networks allowed to relay WITHOUT auth (default 127.0.0.0/8)
#   MESSAGE_SIZE_LIMIT bytes (default 26214400 = 25 MiB)
#   ALLOW_PORT_25      "yes" to also listen on 25 (unauth, MYNETWORKS only)
# Mounted files:
#   /run/secrets/smtp-tls/tls.crt, tls.key   server certificate (cert-manager secret)
#   /run/secrets/smtp-users/users       client logins, one "user[@realm]:password" per line
set -eu

log() { echo "entrypoint: $*" >&2; }

: "${RELAY_HOST:?RELAY_HOST must be set}"
RELAY_PORT="${RELAY_PORT:-587}"
MAIL_HOSTNAME="${MAIL_HOSTNAME:-$(hostname -f)}"
SASL_REALM="${SASL_REALM:-$MAIL_HOSTNAME}"
MYNETWORKS="${MYNETWORKS:-127.0.0.0/8}"
MESSAGE_SIZE_LIMIT="${MESSAGE_SIZE_LIMIT:-26214400}"
TLS_DIR=/run/secrets/smtp-tls
USERS_FILE=/run/secrets/smtp-users/users
SASLDB=/etc/sasl2/sasldb2

[ -s "$TLS_DIR/tls.crt" ] && [ -s "$TLS_DIR/tls.key" ] || { log "missing $TLS_DIR/tls.crt or tls.key"; exit 1; }
[ -s "$USERS_FILE" ] || { log "missing $USERS_FILE (client logins)"; exit 1; }

# ---------- main.cf ----------
postconf -e \
  "compatibility_level=3.6" \
  "maillog_file=/dev/stdout" \
  "myhostname=$MAIL_HOSTNAME" \
  "mydestination=" \
  "local_transport=error:local delivery disabled" \
  "alias_maps=" \
  "alias_database=" \
  "inet_interfaces=all" \
  "inet_protocols=ipv4" \
  "mynetworks=$MYNETWORKS" \
  "message_size_limit=$MESSAGE_SIZE_LIMIT" \
  "smtpd_banner=\$myhostname ESMTP" \
  "disable_vrfy_command=yes" \
  "smtpd_helo_required=yes" \
  \
  "smtpd_tls_cert_file=$TLS_DIR/tls.crt" \
  "smtpd_tls_key_file=$TLS_DIR/tls.key" \
  "smtpd_tls_security_level=may" \
  "smtpd_tls_auth_only=yes" \
  "smtpd_tls_protocols=>=TLSv1.2" \
  "smtpd_tls_mandatory_protocols=>=TLSv1.2" \
  "smtpd_tls_loglevel=1" \
  "smtpd_tls_received_header=yes" \
  \
  "smtpd_sasl_type=cyrus" \
  "smtpd_sasl_path=smtpd" \
  "cyrus_sasl_config_path=/etc/postfix/sasl" \
  "smtpd_sasl_local_domain=$SASL_REALM" \
  "smtpd_sasl_security_options=noanonymous" \
  "smtpd_sasl_authenticated_header=no" \
  "broken_sasl_auth_clients=yes" \
  "smtpd_relay_restrictions=permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination" \
  "smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject" \
  \
  "relayhost=[$RELAY_HOST]:$RELAY_PORT" \
  "smtp_tls_security_level=secure" \
  "smtp_tls_CAfile=/etc/ssl/certs/ca-certificates.crt" \
  "smtp_tls_protocols=>=TLSv1.2" \
  "smtp_tls_loglevel=1" \
  "smtp_tls_wrappermode=${RELAY_TLS_WRAPPER:-no}"

# Upstream credentials (texthash needs no postmap step)
if [ -n "${RELAY_USER:-}" ]; then
  umask 077
  printf '[%s]:%s %s:%s\n' "$RELAY_HOST" "$RELAY_PORT" "$RELAY_USER" "${RELAY_PASSWORD:?RELAY_PASSWORD must be set with RELAY_USER}" \
    > /etc/postfix/sasl_passwd
  umask 022
  postconf -e \
    "smtp_sasl_auth_enable=yes" \
    "smtp_sasl_password_maps=texthash:/etc/postfix/sasl_passwd" \
    "smtp_sasl_security_options=noanonymous" \
    "smtp_sasl_tls_security_options=noanonymous"
else
  postconf -e "smtp_sasl_auth_enable=no"
fi

# ---------- master.cf ----------
if [ "${ALLOW_PORT_25:-no}" != "yes" ]; then
  postconf -MX smtp/inet || true
fi

postconf -M "submission/inet=submission inet n - n - - smtpd"
postconf -P \
  "submission/inet/syslog_name=postfix/submission" \
  "submission/inet/smtpd_tls_security_level=encrypt" \
  "submission/inet/smtpd_sasl_auth_enable=yes" \
  "submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"

postconf -M "submissions/inet=submissions inet n - n - - smtpd"
postconf -P \
  "submissions/inet/syslog_name=postfix/submissions" \
  "submissions/inet/smtpd_tls_wrappermode=yes" \
  "submissions/inet/smtpd_sasl_auth_enable=yes" \
  "submissions/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"

# ---------- client SASL users (sasldb) ----------
mkdir -p /etc/postfix/sasl /etc/sasl2
cat > /etc/postfix/sasl/smtpd.conf <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN
sasldb_path: $SASLDB
EOF

rm -f "$SASLDB"
count=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  login="${line%%:*}"
  pass="${line#*:}"
  if [ "$login" = "$line" ] || [ -z "$pass" ]; then log "skipping malformed users line"; continue; fi
  case "$login" in
    *@*) user="${login%@*}"; realm="${login##*@}" ;;
    *)   user="$login";      realm="$SASL_REALM" ;;
  esac
  printf '%s' "$pass" | saslpasswd2 -p -c -f "$SASLDB" -u "$realm" "$user"
  count=$((count + 1))
done < "$USERS_FILE"
[ "$count" -gt 0 ] || { log "no valid users in $USERS_FILE"; exit 1; }
chown root:postfix "$SASLDB"
chmod 0640 "$SASLDB"
log "loaded $count SASL user(s); realm for bare usernames: $SASL_REALM"

# ---------- start ----------
postfix check
postfix set-permissions >/dev/null 2>&1 || true

# Reload postfix when cert-manager rotates the certificate.
(
  last="$(cat "$TLS_DIR/tls.crt" "$TLS_DIR/tls.key" | md5sum)"
  while sleep 300; do
    now="$(cat "$TLS_DIR/tls.crt" "$TLS_DIR/tls.key" 2>/dev/null | md5sum)" || continue
    if [ "$now" != "$last" ]; then
      log "TLS certificate changed, reloading postfix"
      postfix reload || true
      last="$now"
    fi
  done
) &

log "relaying via [$RELAY_HOST]:$RELAY_PORT as $MAIL_HOSTNAME"
exec postfix start-fg
