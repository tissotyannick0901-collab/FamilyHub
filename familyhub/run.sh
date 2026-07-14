#!/bin/bash
set -e

echo "=== FamilyHub Add-on v3.1.0 ==="

# ── Lire la config HA ────────────────────────────────────────────
CONFIG_PATH=/data/options.json
SECRET=""
LOG_LEVEL="info"

if [ -f "$CONFIG_PATH" ]; then
    SECRET=$(jq -r '.secret // ""' "$CONFIG_PATH" 2>/dev/null || echo "")
    LOG_LEVEL=$(jq -r '.log_level // "info"' "$CONFIG_PATH" 2>/dev/null || echo "info")
fi

# ── Ingress path fourni par HA ───────────────────────────────────
# HA injecte INGRESS_ENTRY=/api/hassio_ingress/TOKEN
INGRESS_ENTRY="${INGRESS_ENTRY:-/}"
echo "Ingress entry : $INGRESS_ENTRY"

# ── Générer la config nginx avec le bon chemin ingress ───────────
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

        # Racine de l'app
        root /app/www;
        index index.html;

        gzip on;
        gzip_types text/html text/css application/javascript application/json;

        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;

        # Support ingress HA — le chemin peut être / ou /api/hassio_ingress/TOKEN/
        location ${INGRESS_ENTRY} {
            alias /app/www/;
            index index.html;
            try_files \$uri \$uri/ ${INGRESS_ENTRY}index.html;
        }

        # API Node.js
        location ${INGRESS_ENTRY}api/ {
            proxy_pass http://127.0.0.1:3001/api/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_read_timeout 30s;
        }

        # Fallback pour accès direct (sans ingress)
        location / {
            try_files \$uri \$uri/ /index.html;
        }

        location /api/ {
            proxy_pass http://127.0.0.1:3001/api/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_read_timeout 30s;
        }

        location /health {
            proxy_pass http://127.0.0.1:3001/api/health;
            access_log off;
        }
    }
}
NGINXEOF

echo "Config nginx générée avec ingress path: $INGRESS_ENTRY"

# ── Variables d'environnement Node.js ────────────────────────────
export PORT=3001
export DB_PATH=/data/familyhub.db
export SECRET="$SECRET"
export LOG_LEVEL="$LOG_LEVEL"
export ALLOWED_ORIGINS="*"
export HA_TOKEN="${SUPERVISOR_TOKEN:-}"
export HA_URL="http://supervisor/core"

echo "Port API   : $PORT"
echo "DB         : $DB_PATH"
echo "Auth       : ${SECRET:+activée}"
echo "Token HA   : ${HA_TOKEN:+présent}"

# ── Démarrer nginx en arrière-plan ───────────────────────────────
echo "Démarrage nginx..."
nginx &
NGINX_PID=$!
echo "nginx PID : $NGINX_PID"

sleep 1

# ── Node.js en PID 1 ─────────────────────────────────────────────
echo "Démarrage FamilyHub API..."
cd /app
exec node server.js
