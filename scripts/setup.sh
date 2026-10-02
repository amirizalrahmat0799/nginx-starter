#!/usr/bin/env bash
# nginx-starter: install Nginx on Ubuntu and publish one site, configured by site.env.
#
#   cp site.env.example site.env   # edit it
#   sudo ./scripts/setup.sh        # or: sudo ./scripts/setup.sh path/to/other.env
#
# Safe to re-run: change site.env (or a template) and run it again to apply.

set -euo pipefail   # stop on errors, on unset variables, and on failures inside pipes

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$REPO_DIR/site.env}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. checks
[[ $EUID -eq 0 ]] || fail "run with sudo:  sudo $0"
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE not found. Create it with:  cp site.env.example site.env"

set -a; source "$ENV_FILE"; set +a     # every VAR=value in site.env becomes an environment variable

: "${DOMAIN:?set DOMAIN in site.env}"
MODE="${MODE:-static}"
HTTPS="${HTTPS:-none}"
INCLUDE_WWW="${INCLUDE_WWW:-false}"

[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]   || fail "DOMAIN '$DOMAIN' is not a valid domain name"
[[ "$MODE" =~ ^(static|proxy)$ ]]     || fail "MODE must be static or proxy (got '$MODE')"
[[ "$HTTPS" =~ ^(none|self-signed|letsencrypt)$ ]] || fail "HTTPS must be none, self-signed or letsencrypt (got '$HTTPS')"
if [[ "$MODE" == proxy ]]; then
    [[ "${UPSTREAM:-}" =~ ^https?:// ]] || fail "MODE=proxy needs UPSTREAM, e.g. http://127.0.0.1:8080"
fi
if [[ "$HTTPS" == letsencrypt ]]; then
    [[ "${EMAIL:-}" == *@* && "${EMAIL}" != you@example.com ]] || fail "HTTPS=letsencrypt needs your real EMAIL"
    [[ "$DOMAIN" != *.test && "$DOMAIN" != *.local ]] || fail "Let's Encrypt only works for real public domains, not $DOMAIN"
fi

SERVER_NAMES="$DOMAIN"
[[ "$INCLUDE_WWW" == true ]] && SERVER_NAMES="$DOMAIN www.$DOMAIN"
SITE_ROOT="/var/www/$DOMAIN"
CERT_DIR="/etc/ssl/nginx-starter"
UPSTREAM="${UPSTREAM:-}"
export DOMAIN SERVER_NAMES SITE_ROOT CERT_DIR UPSTREAM

# Fill a template. Only OUR variables are replaced; Nginx's own ($host, $uri, ...) are left alone.
render() { envsubst '${DOMAIN} ${SERVER_NAMES} ${SITE_ROOT} ${CERT_DIR} ${UPSTREAM} ${HTTP2_DIRECTIVE}' < "$1" > "$2"; }

echo "Site:  $SERVER_NAMES   mode=$MODE   https=$HTTPS"

# ---------------------------------------------------------------- 1. packages
step "Installing packages"
export DEBIAN_FRONTEND=noninteractive
packages=(nginx gettext-base openssl ufw)                     # gettext-base provides envsubst
[[ "$HTTPS" == letsencrypt ]] && packages+=(certbot python3-certbot-nginx)
apt-get update -qq
apt-get install -y -qq "${packages[@]}" >/dev/null

# `http2 on;` exists from Nginx 1.25.1 (Ubuntu 26.04). Older versions just skip HTTP/2.
nginx_version="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
if [[ "$(printf '%s\n1.25.1\n' "$nginx_version" | sort -V | head -1)" == 1.25.1 ]]; then
    HTTP2_DIRECTIVE="http2 on;"
else
    HTTP2_DIRECTIVE="# http2 needs Nginx 1.25.1+, this server has $nginx_version"
fi
export HTTP2_DIRECTIVE
echo "Nginx $nginx_version"

# ---------------------------------------------------------------- 2. firewall
step "Firewall: allow SSH, HTTP and HTTPS only"
# Keep SSH (22) open BEFORE enabling the firewall, or you lock yourself out of a remote server.
if ufw allow 22/tcp >/dev/null && ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null \
        && ufw --force enable >/dev/null 2>&1; then
    ufw status | sed 's/^/    /'
else
    echo "    could not enable ufw here (e.g. inside a container), skipping the firewall"
fi

# ---------------------------------------------------------------- 3. shared config
step "Copying shared config to /etc/nginx"
install -d /etc/nginx/snippets/starter
install -m 644 "$REPO_DIR"/nginx/snippets/*.conf /etc/nginx/snippets/starter/
install -m 644 "$REPO_DIR"/nginx/conf.d/starter.conf /etc/nginx/conf.d/starter.conf

# ---------------------------------------------------------------- 4. site content
step "Site content ($MODE)"
if [[ "$MODE" == static ]]; then
    install -d -m 755 "$SITE_ROOT"
    if [[ ! -e "$SITE_ROOT/index.html" ]]; then             # never overwrite your own files
        sed "s/{{DOMAIN}}/$DOMAIN/g" "$REPO_DIR/html/index.html" > "$SITE_ROOT/index.html"
        echo "    created $SITE_ROOT/index.html"
    fi
    # Let the normal (sudo) user edit the files without sudo; Nginx only needs to read them.
    [[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER":www-data "$SITE_ROOT"
    chmod -R u=rwX,g=rX,o=rX "$SITE_ROOT"
    echo "    serving files from $SITE_ROOT"
    render "$REPO_DIR/nginx/templates/body-static.conf.template" "/etc/nginx/snippets/starter/site-$DOMAIN.conf"
else
    echo "    forwarding to $UPSTREAM"
    render "$REPO_DIR/nginx/templates/body-proxy.conf.template" "/etc/nginx/snippets/starter/site-$DOMAIN.conf"
fi

# ---------------------------------------------------------------- 5. server block
step "Writing /etc/nginx/sites-available/$DOMAIN.conf"
site_file="/etc/nginx/sites-available/$DOMAIN.conf"

if [[ "$HTTPS" == self-signed ]]; then
    install -d -m 755 "$CERT_DIR"
    if [[ ! -f "$CERT_DIR/$DOMAIN.crt" ]]; then
        san="DNS:$DOMAIN"; [[ "$INCLUDE_WWW" == true ]] && san="$san,DNS:www.$DOMAIN"
        # -x509: self-signed cert (no CA)   -nodes: key without password, so Nginx can start unattended
        openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
            -keyout "$CERT_DIR/$DOMAIN.key" -out "$CERT_DIR/$DOMAIN.crt" \
            -subj "/CN=$DOMAIN" -addext "subjectAltName=$san" 2>/dev/null
        chmod 600 "$CERT_DIR/$DOMAIN.key"
        echo "    created self-signed certificate $CERT_DIR/$DOMAIN.crt (valid 825 days)"
    fi
    render "$REPO_DIR/nginx/templates/site-https.conf.template" "$site_file"
else
    # none, and letsencrypt (certbot adds the HTTPS part in step 7)
    render "$REPO_DIR/nginx/templates/site-http.conf.template" "$site_file"
fi

# sites-available = all configs, sites-enabled = the ones Nginx actually loads (symlinks).
ln -sfn "$site_file" "/etc/nginx/sites-enabled/$DOMAIN.conf"
# Disable Ubuntu's "Welcome to nginx" site (the file stays in sites-available).
rm -f /etc/nginx/sites-enabled/default

# ---------------------------------------------------------------- 6. test + reload
step "Testing config and reloading Nginx"
nginx -t                                   # never reload a broken config
if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl enable --now nginx >/dev/null 2>&1
    systemctl reload nginx                 # reload = apply config without dropping connections
else
    pgrep -x nginx >/dev/null && nginx -s reload || nginx
fi

# ---------------------------------------------------------------- 7. Let's Encrypt
if [[ "$HTTPS" == letsencrypt ]]; then
    step "Getting a Let's Encrypt certificate"
    domain_args=(); for name in $SERVER_NAMES; do domain_args+=(-d "$name"); done
    # --nginx: prove domain ownership through Nginx and add the HTTPS config for us
    # --redirect: send HTTP to HTTPS   --keep-until-expiring: re-runs reuse the existing cert
    certbot --nginx --non-interactive --agree-tos -m "$EMAIL" \
        --redirect --keep-until-expiring "${domain_args[@]}"
    echo "    Auto-renewal is handled by the certbot timer:  systemctl list-timers | grep certbot"
fi

# ---------------------------------------------------------------- done
scheme=http; port=80; insecure=""
[[ "$HTTPS" != none ]] && { scheme=https; port=443; }
[[ "$HTTPS" == self-signed ]] && insecure="-k "   # -k: accept the self-signed certificate
step "Done"
cat <<MSG
    URL:        $scheme://$DOMAIN
    Config:     $site_file
    Logs:       /var/log/nginx/$DOMAIN.access.log  and  .error.log
    Test here:  curl -I $insecure$scheme://$DOMAIN --resolve $DOMAIN:$port:127.0.0.1
MSG
