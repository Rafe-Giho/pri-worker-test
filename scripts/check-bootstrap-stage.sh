#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_IP=""
BOOTSTRAP_PASSWORD=""
BOOTSTRAP_USER="bootstrap"
DIST_DIR="$HOME/dist/bootstrap-https"
NODE_BUNDLE="ovpn-node-ng-a-01.tar.gz"
GATEWAY_BUNDLE="ovpn-gw-pri-01.tar.gz"
RUNTIME_BUNDLE="node-runtime-ubuntu2204-amd64.tar.gz"

usage() {
  cat <<'EOF'
usage:
  check-bootstrap-stage.sh --bootstrap-ip <ip> --bootstrap-password <password> [options]

options:
  --bootstrap-user <user>        default: bootstrap
  --dist-dir <path>              default: $HOME/dist/bootstrap-https
  --node-bundle <filename>       default: ovpn-node-ng-a-01.tar.gz
  --gateway-bundle <filename>    default: ovpn-gw-pri-01.tar.gz
  --runtime-bundle <filename>    default: node-runtime-ubuntu2204-amd64.tar.gz
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap-ip) BOOTSTRAP_IP="${2:?}"; shift 2 ;;
    --bootstrap-password) BOOTSTRAP_PASSWORD="${2:?}"; shift 2 ;;
    --bootstrap-user) BOOTSTRAP_USER="${2:?}"; shift 2 ;;
    --dist-dir) DIST_DIR="${2:?}"; shift 2 ;;
    --node-bundle) NODE_BUNDLE="${2:?}"; shift 2 ;;
    --gateway-bundle) GATEWAY_BUNDLE="${2:?}"; shift 2 ;;
    --runtime-bundle) RUNTIME_BUNDLE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$BOOTSTRAP_IP" || -z "$BOOTSTRAP_PASSWORD" ]]; then
  usage
  exit 1
fi

ok() { printf '[OK] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }
check_file() {
  local path="$1"
  if sudo test -f "$path"; then
    ok "file exists: $path"
  else
    fail "missing file: $path"
  fi
}
check_dir() {
  local path="$1"
  if sudo test -d "$path"; then
    ok "dir exists: $path"
  else
    fail "missing dir: $path"
  fi
}

echo "[INFO] bootstrap stage verification start"

for pkg in nginx-core nginx-common apache2-utils; do
  dpkg -s "$pkg" >/dev/null 2>&1 || fail "package not installed: $pkg"
  ok "package installed: $pkg"
done

check_dir /srv/bootstrap/ovpn/issued
check_dir /srv/bootstrap/ovpn/packages
check_dir /srv/bootstrap/ovpn/revoked

check_file /etc/nginx/tls/bootstrap.crt
check_file /etc/nginx/tls/bootstrap.key
check_file /etc/nginx/.htpasswd-ovpn
check_file /etc/nginx/sites-available/bootstrap-ovpn.conf

if sudo test -L /etc/nginx/sites-enabled/bootstrap-ovpn.conf; then
  ok "symlink exists: /etc/nginx/sites-enabled/bootstrap-ovpn.conf"
else
  fail "missing symlink: /etc/nginx/sites-enabled/bootstrap-ovpn.conf"
fi

check_file "/srv/bootstrap/ovpn/issued/$NODE_BUNDLE"
check_file "/srv/bootstrap/ovpn/issued/$GATEWAY_BUNDLE"
check_file "/srv/bootstrap/ovpn/packages/$RUNTIME_BUNDLE"

if test -f "$DIST_DIR/bootstrap-root-ca.pem"; then
  ok "file exists: $DIST_DIR/bootstrap-root-ca.pem"
else
  fail "missing file: $DIST_DIR/bootstrap-root-ca.pem"
fi

sudo nginx -t >/dev/null
ok "nginx config test passed"

if systemctl is-active --quiet nginx; then
  ok "nginx service active"
else
  fail "nginx service is not active"
fi

if sudo openssl x509 -in /etc/nginx/tls/bootstrap.crt -noout -text | grep -q "IP Address:$BOOTSTRAP_IP"; then
  ok "bootstrap certificate SAN includes $BOOTSTRAP_IP"
else
  fail "bootstrap certificate SAN does not include $BOOTSTRAP_IP"
fi

curl -fsSI --cacert "$DIST_DIR/bootstrap-root-ca.pem" \
  -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  "https://${BOOTSTRAP_IP}/ovpn/packages/${RUNTIME_BUNDLE}" >/dev/null
ok "runtime bundle HEAD request succeeded"

curl -fsSI --cacert "$DIST_DIR/bootstrap-root-ca.pem" \
  -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  "https://${BOOTSTRAP_IP}/ovpn/issued/${NODE_BUNDLE}" >/dev/null
ok "node bundle HEAD request succeeded"

curl -fsSI --cacert "$DIST_DIR/bootstrap-root-ca.pem" \
  -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  "https://${BOOTSTRAP_IP}/ovpn/issued/${GATEWAY_BUNDLE}" >/dev/null
ok "gateway bundle HEAD request succeeded"

echo "[INFO] bootstrap stage verification complete"
