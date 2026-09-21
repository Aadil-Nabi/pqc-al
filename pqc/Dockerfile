FROM fedora:43
# Optional corporate TLS-inspection CA(s): drop PEM files as certs/corp-ca/*.crt (see certs/corp-ca/README.md)
COPY certs/corp-ca/ /tmp/corp-ca/
RUN if ls /tmp/corp-ca/*.crt >/dev/null 2>&1; then \
      cp /tmp/corp-ca/*.crt /etc/pki/ca-trust/source/anchors/ && update-ca-trust; \
    fi; rm -rf /tmp/corp-ca
RUN dnf -y install nginx openssl && dnf clean all
COPY pqc/nginx.conf /etc/nginx/nginx.conf
RUN openssl req -x509 -newkey rsa:3072 -sha384 -nodes -days 365 \
      -keyout /etc/pki/tls/private/pqc.key \
      -out    /etc/pki/tls/certs/pqc.crt \
      -subj "/C=SG/O=Meridian Bank/CN=pqc-web.lab"
EXPOSE 443
CMD ["nginx", "-g", "daemon off;"]
