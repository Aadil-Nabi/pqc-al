FROM fedora:43
RUN dnf -y install openssl curl nmap bind-utils jq git ca-certificates \
    && dnf clean all
WORKDIR /work
CMD ["sleep", "infinity"]
