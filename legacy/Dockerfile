FROM nginx:1.20-alpine
# Optional corporate TLS-inspection CA(s): drop PEM files as certs/corp-ca/*.crt (see certs/corp-ca/README.md)
COPY certs/corp-ca/ /tmp/corp-ca/
RUN if ls /tmp/corp-ca/*.crt >/dev/null 2>&1; then \
      cat /tmp/corp-ca/*.crt >> /etc/ssl/certs/ca-certificates.crt; \
    fi; rm -rf /tmp/corp-ca
RUN apk add --no-cache openssl && \
    openssl req -x509 -newkey rsa:2048 -sha1 -nodes -days 3650 \
      -keyout /etc/ssl/private/legacy.key \
      -out    /etc/ssl/certs/legacy.crt \
      -subj "/C=SG/O=Meridian Bank/CN=legacy-web.lab"
COPY legacy/nginx.conf /etc/nginx/nginx.conf
EXPOSE 443
