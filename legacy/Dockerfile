FROM nginx:1.20-alpine
RUN apk add --no-cache openssl && \
    openssl req -x509 -newkey rsa:2048 -sha1 -nodes -days 3650 \
      -keyout /etc/ssl/private/legacy.key \
      -out    /etc/ssl/certs/legacy.crt \
      -subj "/C=SG/O=Meridian Bank/CN=legacy-web.lab"
COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 443
