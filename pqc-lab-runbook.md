# PQC Assessment Workshop Lab — Build Runbook

Everything here runs on **one machine**. Two things sit outside it: the CipherTrust
Manager appliance and the HSM. Build in the order below; each step has a check you
must pass before moving on.

---

## 1. Servers you actually need

| # | Name | What it is | Spec | Why |
|---|------|-----------|------|-----|
| 1 | **Lab host** | Physical box or VM | 8 vCPU, 32 GB RAM, 200 GB disk, Ubuntu 24.04 LTS | Runs every container below |
| 2 | `pqc-web` | Container (Fedora 43 + nginx) | ~200 MB | Modern endpoint. Fedora 43 ships OpenSSL 3.5 as the system library, so ML-KEM works with no provider build |
| 3 | `legacy-web` | Container (nginx 1.20 / OpenSSL 1.1.1) | ~50 MB | The "before" picture: TLS 1.0–1.2, RSA-2048, SHA-1 cert |
| 4 | `toolbox` | Container (Fedora 43) | ~400 MB | Client, cert factory, nmap. Shares `/work` with the host |
| 5 | `sonarqube` | Container | 4 GB RAM, 20 GB disk | Hosts the sonar-cryptography plugin that emits `cbom.json` |
| 6 | **CTM** | Separate VM (OVA from Thales) | 4 vCPU, 8 GB RAM, 100 GB disk (confirm against 2.21 release notes) | ML-KEM key generation demo |
| 7 | **HSM** | DPoD Cloud HSM tenant, or physical Luna | no VM needed for DPoD | PQC firmware/client story |

**Do not skip the host prep.** SonarQube will not start without it:

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2 git jq
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
sudo usermod -aG docker "$USER"   # log out and back in
```

**Behind a corporate TLS-inspecting proxy (Zscaler, Netskope, ...)?** Pulls and the
package installs inside the builds will fail with `x509: certificate signed by
unknown authority`. Export the proxy's CA chain as PEM, drop it in
`certs/corp-ca/*.crt`, and trust it on the host too — see `certs/corp-ca/README.md`.
Every Dockerfile picks the folder up automatically; the folder is gitignored.

---

## 2. Bring the lab up

**Where:** lab host, in the unpacked `pqc-lab/` directory.

```bash
cd pqc-lab
docker compose build
docker compose up -d
docker compose ps
```

**Check — this is the whole point of the lab, so get it working before anything else:**

```bash
# The client speaks PQC natively
docker compose exec toolbox openssl version
docker compose exec toolbox openssl list -kem-algorithms | grep -i mlkem
docker compose exec toolbox openssl list -signature-algorithms | grep -i ml-dsa

# Modern endpoint negotiates a hybrid group
docker compose exec toolbox openssl s_client \
  -connect pqc-web.lab:443 -groups X25519MLKEM768 -tls1_3 </dev/null 2>&1 \
  | grep -i "Negotiated"

# Legacy endpoint cannot. Screenshot this failure — it is your opening slide.
docker compose exec toolbox openssl s_client \
  -connect legacy-web.lab:443 -groups X25519MLKEM768 -tls1_3 </dev/null 2>&1 | grep -Ei "Cipher is|alert|error"
```

Expected: `Negotiated TLS1.3 group: X25519MLKEM768` on the first. On the second,
`New, (NONE), Cipher is (NONE)` plus a `tlsv1 alert protocol version` line: the
legacy server cannot speak TLS 1.3 at all, let alone a hybrid group.

**If `openssl list -kem-algorithms` shows no MLKEM**, you are not on OpenSSL 3.5+.
Nothing else will work. On Ubuntu 24.04 the system OpenSSL is 3.0 — that is exactly
why the containers are Fedora-based, and it is a useful thing to show the team:
their own laptops are in the same position as the customer's servers.

**Browser check (optional, five minutes, good demo):** from a machine that can reach
the host, open `https://<host>:8443` in Chrome, accept the self-signed warning, then
open DevTools → Security. Modern Chrome offers `X25519MLKEM768` by default. Compare
with `https://<host>:9443`.

---

## 3. Build the certificate estate

**Where:** inside the `toolbox` container (needs OpenSSL 3.5 for ML-DSA).

```bash
docker compose exec toolbox bash /work/certs/make-estate.sh 200
```

This produces:

- `certs/estate/ca.crt` — classical RSA-4096 root
- `certs/estate/mldsa-ca.crt` — ML-DSA-65 root. A private CA is currently the only
  way to get PQC certificates; public CAs and root programmes have not caught up
- `certs/estate/leaf/` — 200 leaf certs with a deliberate mix: RSA-1024 through
  RSA-4096, P-256, P-384, some SHA-1 signed, some already expired, some valid past 2030
- `certs/estate/cert-inventory.csv` — the inventory, with column names shaped toward
  the CycloneDX 1.6 cryptographic-asset fields

**The exercise, not the script, is the point.** Hand the team the CSV and have them
populate the Crypto Inventory tab of the frozen workbook from it. Watch for anyone
typing free text where a controlled value belongs. Every place that happens is a
place your CBOM generation will break later.

Three questions to put to the room while they work:

1. How many certificates are valid past 2030, and who signed off on that validity period?
2. How long would it take this bank to reissue all 200? That number *is* the crypto-agility answer.
3. Which of these would you grade C4, and what evidence would you need to see?

---

## 4. Network-layer discovery

**Where:** lab host.

```bash
./scans/run-scans.sh
ls scans/out/
```

Outputs go to `scans/out/` — handshake transcripts, nmap cipher enumeration, and
full testssl.sh runs on both endpoints.

Check whether your testssl build reports ML-KEM groups. If it does not, say so out
loud during the session and fall back to `s_client`. Letting the team claim a tool
sees something it does not is the exact habit you are running this workshop to prevent.

---

## 5. Source-code CBOM

The CBOMkit toolset has moved between the IBM, PQCA and cbomkit GitHub
organisations. **Check the current canonical repo before you download anything** —
do not paste a URL from an old deck into a customer-facing artefact.

The detection engine is `sonar-cryptography`, a SonarQube plugin. It covers Java
(JCA, BouncyCastle), Python (pyca/cryptography) and Go, needs SonarQube 9.9 LTS or
newer, and only the "Cryptographic Inventory (CBOM)" rule writes a `cbom.json`.

**Where:** lab host.

```bash
# once: install the plugin
docker cp sonar-cryptography-<version>.jar sonarqube:/opt/sonarqube/extensions/plugins/
docker compose restart sonarqube

# If port 9000 is already taken on the host (MinIO uses it), pick another before
# starting:  export SONAR_PORT=9900 && docker compose up -d sonarqube
# log in at http://<host>:9000  (admin / admin), change the password,
# create project "meridian-badcrypto", generate a token
export SONAR_TOKEN=squ_xxxxxxxx

./scans/cbom-scan.sh
jq '.components[] | {name, type, cryptoProperties}' badcrypto/cbom.json | head -60
```

`badcrypto/` is a deliberately messy sample: MD5, SHA-1, DES/ECB, 3DES, a hardcoded
key and static IV, RSA-1024, RSA-2048, ECDSA P-256 — plus one correct AES-256-GCM
path so there is something to contrast against.

**Deployment artefacts, not just source.** `cbomkit-theia` is the complementary tool:
it finds certificates, keys, secrets and config inside container images rather than
API calls in code. Run it against one of your own images so the team sees the gap
between the two scans. Source scanning alone will miss most of a bank's estate.

**The real exercise:** have someone reconcile ten `cbom.json` entries by hand against
the workbook register. Every mapping gap you find here is one you will not discover
in front of the customer.

---

## 6. Thales stack

**Where:** separate VM plus DPoD tenant. Keep this last on the agenda and keep it short —
Phase 1 is an assessment, and credibility comes from not selling during it.

1. Deploy the CTM 2.21 OVA, run first-boot config, apply the licence.
2. Enable the PQC features and generate an ML-KEM key through both GUI and CLI.
3. For the HSM, use a DPoD Cloud HSM trial if no hardware is free.
4. **Verify the firmware and client versions currently required for PQC against the
   live Thales release notes**, not against notes from an earlier engagement.

---

## 7. Teardown and reset

```bash
docker compose down -v          # drops SonarQube data too
rm -rf certs/estate scans/out badcrypto/cbom.json
```

Snapshot the host after step 5 succeeds. If a workshop attendee breaks something on
day 1, you want a ten-minute restore, not a rebuild.

---

## Build schedule

| When | What | Effort |
|------|------|--------|
| Day 1 | Host prep, `docker compose up`, section 2 checks pass | 3 hours |
| Day 1 | Certificate estate + inventory exercise dry run | 2 hours |
| Day 2 | Network scans, review the output yourself first | 2 hours |
| Day 2 | SonarQube plugin, CBOM scan, manual reconciliation | 4 hours |
| Day 3 | CTM and HSM, snapshot the host | 3 hours |

Start the mock-customer pack in parallel on day 1. It takes longer to write than the
lab takes to build, and it matters more.
