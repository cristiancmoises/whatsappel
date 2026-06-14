FROM node:20-alpine

LABEL maintainer="berkeley, Cristian Cezar Moisés"
LABEL description="WhatsApp.el bridge server (Baileys)"

RUN apk add --no-cache tini

WORKDIR /app

COPY package.json ./
RUN npm install --production && npm cache clean --force

COPY server.js ./

RUN mkdir -p /data/auth /data/media /data/store

ENV WAEL_PORT=3000 \
    WAEL_WS_PORT=3001 \
    WAEL_AUTH_DIR=/data/auth \
    WAEL_MEDIA_DIR=/data/media \
    WAEL_STORE_FILE=/data/store/store.json \
    WAEL_LOG_LEVEL=info \
    NODE_ENV=production

EXPOSE 3000 3001

VOLUME ["/data"]

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
