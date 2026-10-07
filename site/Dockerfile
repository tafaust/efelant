FROM nginxinc/nginx-unprivileged:1.29-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=101:101 . /usr/share/nginx/html

EXPOSE 8080
