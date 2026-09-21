FROM fedora:43
RUN dnf -y install nginx openssl && dnf clean all
COPY nginx.conf /etc/nginx/nginx.conf
RUN openssl req -x509 -newkey rsa:3072 -sha384 -nodes -days 365 \
      -keyout /etc/pki/tls/private/pqc.key \
      -out    /etc/pki/tls/certs/pqc.crt \
      -subj "/C=SG/O=Meridian Bank/CN=pqc-web.lab"
EXPOSE 443
CMD ["nginx", "-g", "daemon off;"]
