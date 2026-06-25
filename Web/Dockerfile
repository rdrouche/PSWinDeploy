# PSWinDeploy console -- image unique : BFF Node/Express qui sert le frontend
# React, proxifie l'API PowerShell (secrets cote serveur) et stocke les stats
# de deploiement en SQLite (volume persistant).

# ─── Stage 1 : build du frontend (Vite) ───────────────────────────────────
FROM node:20-alpine AS frontend
WORKDIR /app
COPY frontend/package*.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build          # produit /app/dist

# ─── Stage 2 : dependances du BFF (better-sqlite3 compile en natif) ────────
FROM node:20-alpine AS server-deps
WORKDIR /srv
# Outils de build pour la compilation native de better-sqlite3.
RUN apk add --no-cache python3 make g++
COPY server/package*.json ./
RUN npm install --omit=dev

# ─── Stage 3 : image finale ────────────────────────────────────────────────
FROM node:20-alpine
WORKDIR /srv
ENV NODE_ENV=production

COPY --from=server-deps /srv/node_modules ./node_modules
COPY server/package*.json ./
COPY server/index.js ./
COPY server/stats-db.js ./
COPY server/hash-password.js ./
COPY --from=frontend /app/dist ./public

# Volume pour la base SQLite des stats (persiste entre redemarrages).
VOLUME ["/data"]
ENV SQLITE_PATH=/data/pswd-stats.db

EXPOSE 3000
CMD ["node", "index.js"]
