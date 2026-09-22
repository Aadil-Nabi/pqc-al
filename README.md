# pqc-al — PQC Assessment Workshop Lab

A self-contained Docker lab for running post-quantum cryptography (PQC) assessment
workshops. It puts a modern TLS endpoint that negotiates `X25519MLKEM768` next to a
legacy one that cannot, generates a 200-certificate mock estate with the weaknesses a
bank actually has, scans both endpoints with the standard tooling, and produces a
CycloneDX 1.6 cryptographic bill of materials (CBOM) from deliberately bad source
code with SonarQube and the sonar-cryptography plugin.

The point of the lab is the reconciliation work the team does by hand between the
tool output and the assessment workbook. The tools are there to be argued with.

Everything runs on one Ubuntu 24.04 VM with 100 GB thin-provisioned disk and 16 GB
RAM. Verified end to end on 21 September 2026, including behind a corporate
TLS-inspecting proxy.

**Full build instructions, expected outputs and troubleshooting:
[pqc-lab-runbook.md](pqc-lab-runbook.md).**

## What is in here

```
docker-compose.yml     pqc-web, legacy-web, toolbox, sonarqube on one bridge network
pqc/                   Fedora 43 + nginx, OpenSSL 3.5, TLS 1.3 only, hybrid ML-KEM
legacy/                nginx 1.20 / OpenSSL 1.1.1, TLS 1.0–1.2, SHA-1 cert, CBC suites
toolbox/               Fedora 43 client: openssl 3.5, nmap, curl, jq
certs/make-estate.sh   builds the mock certificate estate + CycloneDX-shaped CSV
certs/corp-ca/         drop a corporate proxy CA here if builds fail on x509 errors
scans/run-scans.sh     s_client, nmap ssl-enum-ciphers, testssl.sh -> scans/out/
scans/cbom-scan.sh     compiles badcrypto/, runs sonar-scanner, writes cbom.json
badcrypto/             deliberately weak Java (JCA) and Python (pyca) samples
pqc-lab-runbook.md     the runbook
```

Generated output (`certs/estate/`, `scans/out/`, `badcrypto/cbom.json`), private
keys, tokens, the SonarQube plugin jar and anything under `customer/` or
`engagements/` are gitignored.

## Quick start

```bash
# host prep (once)
sudo apt update && sudo apt install -y docker.io docker-compose-v2 docker-buildx git jq
sudo sysctl -w vm.max_map_count=262144 && echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
sudo usermod -aG docker "$USER" && newgrp docker

# lab
git clone https://github.com/Aadil-Nabi/pqc-al.git pqc-lab && cd pqc-lab
echo 'SONAR_PORT=9900' > .env          # only if 9000 is taken on your host
docker compose build && docker compose up -d

# the check that matters
docker compose exec toolbox openssl s_client -connect pqc-web.lab:443 \
  -groups X25519MLKEM768 -tls1_3 </dev/null 2>&1 | grep Negotiated
#   -> Negotiated TLS1.3 group: X25519MLKEM768

# certificate estate, network scans
docker compose exec toolbox bash /work/certs/make-estate.sh 200
./scans/run-scans.sh

# CBOM (after installing the plugin and activating the rule, see runbook section 5)
export SONAR_TOKEN=sqp_...  SONAR_PROJECT_KEY=Meridian-BadCrypto-Sample
./scans/cbom-scan.sh 2>&1 | grep -v 'constructor definition'
```

Behind Zscaler or a similar proxy, read runbook section 1c before `docker compose build`.

## Ports on the host

| Port | Service |
|---|---|
| 8443 | pqc-web (modern, TLS 1.3 + ML-KEM) |
| 9443 | legacy-web (TLS 1.0–1.2, SHA-1) |
| 9000 or `SONAR_PORT` | SonarQube |
