# PSWinDeploy console -- image unique : BFF Node/Express qui sert le frontend
# React, proxifie l'API PowerShell (secrets cote serveur) et stocke les stats
# de deploiement en SQLite (volume persistant).

# ─── Stage 1 : build du frontend (Vite) ───────────────────────────────────
FROM node:20-alpine AS frontend
WORKDIR /app
COPY frontend/package*.json ./
# npm ci exige un package-lock.json synchronise ; si absent, on retombe sur
# npm install (plus tolerant). Evite l'echec de build quand le lock manque.
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi
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

# better-sqlite3 est compile en natif au stage server-deps. Son binaire .node
# a besoin de la bibliotheque C++ standard au RUNTIME. Sans elle, le chargement
# du module echoue silencieusement -> la base SQLite ne s'initialise pas -> les
# stats restent vides alors que l'API a bien les donnees.
RUN apk add --no-cache libstdc++

# Liens de pied de page (sidebar) -- configurables AU BUILD via --build-arg.
# Chaque ARG devient une valeur ENV par defaut dans l'image. Elle reste
# surchargeable AU RUNTIME (docker compose environment / docker run -e) : la
# valeur runtime l'emporte sur celle du build.
# URL du lien + label affiche (le label a une valeur par defaut sensee).
ARG LINK_GITHUB=""
ARG LINK_GITHUB_LABEL="GitHub"
ARG LINK_KOFI=""
ARG LINK_KOFI_LABEL="Ko-fi"
ARG LINK_DOCS=""
ARG LINK_DOCS_LABEL="Documentation"
ARG LINK_SITE=""
ARG LINK_SITE_LABEL="Site web"
ENV LINK_GITHUB=$LINK_GITHUB \
    LINK_GITHUB_LABEL=$LINK_GITHUB_LABEL \
    LINK_KOFI=$LINK_KOFI \
    LINK_KOFI_LABEL=$LINK_KOFI_LABEL \
    LINK_DOCS=$LINK_DOCS \
    LINK_DOCS_LABEL=$LINK_DOCS_LABEL \
    LINK_SITE=$LINK_SITE \
    LINK_SITE_LABEL=$LINK_SITE_LABEL

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
