#!/usr/bin/env bash
# Odoo 17 on Docker (Ubuntu 20.04/22.04/24.04)
# - Installs Docker + compose plugin
# - Creates docker compose (Odoo+Postgres)
# - Writes odoo.conf (admin_passwd) into a mounted volume
# - Exposes Odoo only on 127.0.0.1:8069
# - Sets up Nginx as reverse proxy + Let's Encrypt HTTPS
# Based on DigitalOcean's tutorial structure (Docker Compose + Nginx + Certbot).

set -euo pipefail

### ====== EDIT THESE ====== ###
DOMAIN="test.alamindev.site"
ADMIN_EMAIL="alaminsc17@gmail.com"
ADMIN_PASS="admin123"    # Odoo master password (Database manager)
PG_USER="odoo"
PG_PASS="Alaminsc17"
PG_DB="postgres"         # default; Odoo will create its own DBs
ODOO_VERSION="17.0"      # Odoo image tag major.minor (17/17.0)
### ======================== ###

# Paths
STACK_DIR="/opt/odoo-docker"
CONF_DIR="${STACK_DIR}/odoo-conf"
EXTRA_ADDONS_DIR="${STACK_DIR}/custom-addons"
COMPOSE_FILE="${STACK_DIR}/compose.yml"
NGINX_SITE="/etc/nginx/sites-available/odoo"
NGINX_LINK="/etc/nginx/sites-enabled/odoo"

log(){ echo -e "\033[1;32m[+]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[!]\033[0m $*"; }
die(){ echo -e "\033[1;31m[x]\033[0m $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."; }

need_root

#--- 0) Basic packages
log "Updating packages…"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release ufw

#--- 1) Docker Engine + compose plugin (per Docker docs)
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine…"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

#--- 2) Directories & network
log "Creating stack directories…"
mkdir -p "${STACK_DIR}" "${CONF_DIR}" "${EXTRA_ADDONS_DIR}"
# Docker network (if not existing)
docker network inspect odoo-net >/dev/null 2>&1 || docker network create odoo-net

#--- 3) odoo.conf (stores master password)
log "Writing odoo.conf…"
cat > "${CONF_DIR}/odoo.conf" <<EOF
[options]
admin_passwd = ${ADMIN_PASS}
db_host = db
db_port = 5432
db_user = ${PG_USER}
db_password = ${PG_PASS}
addons_path = /mnt/extra-addons
proxy_mode = True
limit_time_cpu = 120
limit_time_real = 240
EOF

#--- 4) docker compose (Odoo + Postgres)
log "Writing docker compose file…"
cat > "${COMPOSE_FILE}" <<'YAML'
services:
  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${PG_PASS}
      POSTGRES_DB: ${PG_DB}
    volumes:
      - db-data:/var/lib/postgresql/data
    networks: [odoo-net]

  odoo:
    image: odoo:${ODOO_VERSION}
    depends_on: [db]
    restart: unless-stopped
    environment:
      HOST: db
      USER: ${PG_USER}
      PASSWORD: ${PG_PASS}
    volumes:
      - odoo-data:/var/lib/odoo
      - ${CONF_DIR}/odoo.conf:/etc/odoo/odoo.conf:ro
      - ${EXTRA_ADDONS_DIR}:/mnt/extra-addons
    # bind only to localhost; nginx will reverse-proxy
    ports:
      - "127.0.0.1:8069:8069"
    networks: [odoo-net]

volumes:
  db-data:
  odoo-data:

networks:
  odoo-net:
    external: true
YAML

# Substitute envs in compose file (simple env expansion)
export PG_USER PG_PASS PG_DB ODOO_VERSION CONF_DIR EXTRA_ADDONS_DIR
envsubst < "${COMPOSE_FILE}" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "${COMPOSE_FILE}"

#--- 5) Bring up the stack
log "Starting Odoo + Postgres with docker compose…"
docker compose -f "${COMPOSE_FILE}" up -d

#--- 6) Nginx reverse proxy (host)
log "Installing Nginx & Certbot…"
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot python3-certbot-nginx

log "Writing Nginx site for ${DOMAIN}…"
cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # increase buffers for Odoo responses
    proxy_buffers 16 64k;
    proxy_buffer_size 128k;
    client_max_body_size 64M;

    location / {
        proxy_pass http://127.0.0.1:8069;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host;
        proxy_redirect off;
        proxy_read_timeout 3600;
    }
}
EOF

ln -sf "${NGINX_SITE}" "${NGINX_LINK}" || true
[[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default || true
nginx -t && systemctl reload nginx

#--- 7) Firewall
if command -v ufw >/dev/null 2>&1; then
  log "Configuring UFW…"
  ufw allow OpenSSH || true
  ufw allow 'Nginx Full' || true
  ufw --force enable || true
fi

#--- 8) Let’s Encrypt TLS
log "Issuing TLS cert for ${DOMAIN}…"
if ! certbot --nginx -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos -n --redirect; then
  warn "Certbot failed. Make sure DNS A-record for ${DOMAIN} points to this server, then run:
  certbot --nginx -d ${DOMAIN} -m ${ADMIN_EMAIL} --agree-tos --redirect"
fi

#--- 9) Health checks
log "Waiting 5s, then checking Odoo container logs…"
sleep 5
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker compose -f "${COMPOSE_FILE}" logs --tail=50 --no-color odoo || true

echo
log "Done."
echo "------------------------------------------------------------"
echo "Open: https://${DOMAIN}"
echo "Database manager (master) password: ${ADMIN_PASS}"
echo
echo "Files:"
echo "  Compose: ${COMPOSE_FILE}"
echo "  Config : ${CONF_DIR}/odoo.conf"
echo "  Addons : ${EXTRA_ADDONS_DIR}"
echo "Docker:"
echo "  docker compose -f ${COMPOSE_FILE} ps"
echo "  docker compose -f ${COMPOSE_FILE} logs -f odoo"
echo "------------------------------------------------------------"
