FROM fedora:43
# Optional corporate TLS-inspection CA(s): drop PEM files as certs/corp-ca/*.crt (see certs/corp-ca/README.md)
COPY certs/corp-ca/ /tmp/corp-ca/
RUN if ls /tmp/corp-ca/*.crt >/dev/null 2>&1; then \
      cp /tmp/corp-ca/*.crt /etc/pki/ca-trust/source/anchors/ && update-ca-trust; \
    fi; rm -rf /tmp/corp-ca
RUN dnf -y install openssl curl nmap bind-utils jq git ca-certificates \
    && dnf clean all
WORKDIR /work
CMD ["sleep", "infinity"]
