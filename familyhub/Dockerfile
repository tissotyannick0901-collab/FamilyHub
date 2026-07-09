FROM node:20-alpine

RUN apk add --no-cache nginx bash curl jq

RUN mkdir -p /app/www /data /run/nginx

COPY server/package.json /app/package.json
WORKDIR /app
RUN npm install --production --no-optional

COPY server/server.js /app/server.js
COPY www/index.html /app/www/index.html
COPY nginx.conf /etc/nginx/nginx.conf
COPY run.sh /run.sh
RUN chmod +x /run.sh

EXPOSE 3000
CMD ["/run.sh"]

LABEL io.hass.name="FamilyHub" \
      io.hass.description="Application de gestion familiale" \
      io.hass.type="addon" \
      io.hass.version="3.0.0"
