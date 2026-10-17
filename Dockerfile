# Edge City x Aqua0 residency explorer: static site, indexes the chain in the browser.
#   docker build -t edge-city-aqua0-residency .
#   docker run -p 8787:80 edge-city-aqua0-residency      -> http://localhost:8787
FROM node:22-alpine AS build
WORKDIR /repo/app
COPY app/package.json app/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY app/ ./
COPY deployments/ /repo/deployments/
ARG VITE_RPC_URL=""
ENV VITE_RPC_URL=$VITE_RPC_URL
RUN npm run build

FROM nginx:1.27-alpine
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /repo/app/dist /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
