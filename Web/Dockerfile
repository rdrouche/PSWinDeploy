# PSWinDeploy console -- image unique : BFF Node/Express qui sert le frontend
# React et proxifie l'API PowerShell en gardant les secrets cote serveur.
#
# Publiee via CI (Forgejo / GitHub Actions) sur un registre. Toute la config se
# fait au RUNTIME par variables d'environnement : la meme image marche partout,
# seul le docker-compose change.

# ─── Stage 1 : build du frontend (Vite) ───────────────────────────────────
FROM node:20-alpine AS frontend
WORKDIR /app
COPY frontend/package*.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build          # produit /app/dist

# ─── Stage 2 : dependances du BFF ──────────────────────────────────────────
FROM node:20-alpine AS server-deps
WORKDIR /srv
COPY server/package*.json ./
RUN npm install --omit=dev

# ─── Stage 3 : image finale ────────────────────────────────────────────────
FROM node:20-alpine
WORKDIR /srv
ENV NODE_ENV=production

COPY --from=server-deps /srv/node_modules ./node_modules
COPY server/package*.json ./
COPY server/index.js ./
COPY --from=frontend /app/dist ./public

EXPOSE 3000
CMD ["node", "index.js"]
