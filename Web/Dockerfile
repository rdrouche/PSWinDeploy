# Multi-stage build : compile React/Vite puis sert avec nginx alpine
# Stage 1 : build
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2 : nginx alpine (~25 MB)
FROM nginx:1.27-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
# Template nginx : ${API_BACKEND} substitue au demarrage via envsubst
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
EXPOSE 3000
# nginx:alpine substitue automatiquement les variables dans /etc/nginx/templates/
# La variable API_BACKEND est passee via docker-compose
