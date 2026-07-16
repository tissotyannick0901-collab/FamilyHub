#!/bin/bash
set -e

echo "=== FamilyHub Add-on v3.6.0 ==="

# ── Lire la config HA ────────────────────────────────────────────
CONFIG_PATH=/data/options.json
SECRET=""
LOG_LEVEL="info"
API_PORT=3001

if [ -f "$CONFIG_PATH" ]; then
    SECRET=$(jq -r '.secret // ""' "$CONFIG_PATH" 2>/dev/null || echo "")
    LOG_LEVEL=$(jq -r '.log_level // "info"' "$CONFIG_PATH" 2>/dev/null || echo "info")
    API_PORT=$(jq -r '.api_port // 3001' "$CONFIG_PATH" 2>/dev/null || echo "3001")
fi

echo "Port API   : $API_PORT"
echo "Secret     : ${SECRET:+configuré}"

# ── Config nginx ─────────────────────────────────────────────────
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
        location /api/ {
            proxy_pass http://127.0.0.1:${API_PORT}/api/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_read_timeout 30s;
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET,POST,PUT,DELETE,OPTIONS" always;
            add_header Access-Control-Allow-Headers "Content-Type,Authorization" always;
        }
        location /health {
            proxy_pass http://127.0.0.1:${API_PORT}/api/health;
            access_log off;
        }
        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
NGINXEOF

echo "Config nginx OK (proxy → port $API_PORT)"

# ── Variables Node.js ─────────────────────────────────────────────
export PORT=$API_PORT
export DB_PATH=/data/familyhub.db
export SECRET="$SECRET"
export LOG_LEVEL="$LOG_LEVEL"
export ALLOWED_ORIGINS="*"
export HA_TOKEN="${SUPERVISOR_TOKEN:-}"
export HA_URL="http://supervisor/core"

echo "DB         : $DB_PATH"
echo "Token HA   : ${HA_TOKEN:+présent}"

# ── Démarrer nginx ────────────────────────────────────────────────
echo "Démarrage nginx (port 3000)..."
nginx -t 2>/dev/null && nginx
echo "nginx OK"

sleep 1

# ── Node.js en PID 1 ─────────────────────────────────────────────
echo "Démarrage FamilyHub API (port $API_PORT)..."
cd /app
exec node server.js
