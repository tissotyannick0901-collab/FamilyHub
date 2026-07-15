#!/bin/bash
set -e

echo "=== FamilyHub Add-on v3.5.0 ==="

# ── Lire la config HA ────────────────────────────────────────────
CONFIG_PATH=/data/options.json
SECRET=""
LOG_LEVEL="info"

if [ -f "$CONFIG_PATH" ]; then
    SECRET=$(jq -r '.secret // ""' "$CONFIG_PATH" 2>/dev/null || echo "")
    LOG_LEVEL=$(jq -r '.log_level // "info"' "$CONFIG_PATH" 2>/dev/null || echo "info")
fi

# ── Ingress path fourni par HA ───────────────────────────────────
INGRESS_ENTRY="${INGRESS_ENTRY:-/}"
echo "Ingress entry : $INGRESS_ENTRY"

# ── Générer la config nginx ───────────────────────────────────────
# Si INGRESS_ENTRY est "/", une seule location suffit.
# Si c'est un sous-chemin, on ajoute un alias dédié + fallback /.

if [ "$INGRESS_ENTRY" = "/" ]; then
cat > /etc/nginx/nginx.conf << 'NGINXEOF'
worker_processes 1;
error_log /dev/stderr warn;
pid /run/nginx/nginx.pid;
events { worker_connections 512; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    sendfile on;
    keepalive_timeout 65;
    server {
        listen 3000 default_server;
        server_name _;
        root /app/www;
        index index.html;
        gzip on;
        gzip_types text/html text/css application/javascript application/json;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
        location /api/ {
            proxy_pass http://127.0.0.1:3001/api/;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_read_timeout 30s;
        }
        location /health {
            proxy_pass http://127.0.0.1:3001/api/health;
            access_log off;
        }
        location / {
            try_files $uri $uri/ /index.html;
        }
    }
}
NGINXEOF
else
# Ingress avec sous-chemin (ex: /api/hassio_ingress/TOKEN/)
INGRESS_API="${INGRESS_ENTRY}api/"
cat > /etc/nginx/nginx.conf << NGINXEOF
worker_processes 1;
error_log /dev/stderr warn;
pid /run/nginx/nginx.pid;
events { worker_connections 512; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    sendfile on;
    keepalive_timeout 65;
    server {
        listen 3000 default_server;
        server_name _;
        root /app/www;
        index index.html;
        gzip on;
        gzip_types text/html text/css application/javascript application/json;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
        location ${INGRESS_API} {
            proxy_pass http://127.0.0.1:3001/api/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_read_timeout 30s;
        }
        location ${INGRESS_ENTRY} {
            alias /app/www/;
            index index.html;
            try_files \$uri \$uri/ ${INGRESS_ENTRY}index.html;
        }
        location /api/ {
            proxy_pass http://127.0.0.1:3001/api/;
            proxy_http_version 1.1;
        }
        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
NGINXEOF
fi

echo "Config nginx générée (ingress: $INGRESS_ENTRY)"

# ── Variables Node.js ─────────────────────────────────────────────
export PORT=3001
export DB_PATH=/data/familyhub.db
export SECRET="$SECRET"
export LOG_LEVEL="$LOG_LEVEL"
export ALLOWED_ORIGINS="*"
export HA_TOKEN="${SUPERVISOR_TOKEN:-}"
export HA_URL="http://supervisor/core"

echo "Port API : $PORT | DB : $DB_PATH | Auth : ${SECRET:+oui} | HA : ${HA_TOKEN:+oui}"

# ── Démarrer nginx ────────────────────────────────────────────────
echo "Démarrage nginx..."
nginx -t && nginx
echo "nginx OK"

sleep 1

# ── Node.js en PID 1 ─────────────────────────────────────────────
echo "Démarrage FamilyHub API..."
cd /app
exec node server.js
