#!/bin/bash
set -e

echo "=== FamilyHub Add-on v3.0.0 ==="

# Lire la config HA
CONFIG_PATH=/data/options.json
SECRET=""
LOG_LEVEL="info"

if [ -f "$CONFIG_PATH" ]; then
    SECRET=$(jq -r '.secret // ""' "$CONFIG_PATH" 2>/dev/null || echo "")
    LOG_LEVEL=$(jq -r '.log_level // "info"' "$CONFIG_PATH" 2>/dev/null || echo "info")
fi

export PORT=3001
export DB_PATH=/data/familyhub.db
export SECRET="$SECRET"
export LOG_LEVEL="$LOG_LEVEL"
export ALLOWED_ORIGINS="*"
export HA_TOKEN="${SUPERVISOR_TOKEN:-}"
export HA_URL="http://supervisor/core"

echo "Port API   : $PORT"
echo "DB         : $DB_PATH"
echo "Auth       : ${SECRET:+activée (configurée)}"
echo "Token HA   : ${HA_TOKEN:+présent}"

# Démarrer nginx en arrière-plan
echo "Démarrage nginx (port 3000)..."
nginx -g "daemon off;" &
NGINX_PID=$!
echo "nginx PID : $NGINX_PID"

# Attendre que nginx soit prêt
sleep 1

# Démarrer Node.js — exec = devient PID 1
echo "Démarrage FamilyHub API (port 3001)..."
cd /app
exec node server.js
