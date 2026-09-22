# PQC Assessment Workshop Lab — Build Runbook

Everything here runs on **one machine**. Two things sit outside it: the CipherTrust
Manager appliance and the HSM. Build in the order below; each step has a check you
must pass before moving on.

This runbook was last verified end to end on **21 September 2026** on a fresh Ubuntu
24.04 Desktop VM behind a Zscaler TLS-inspecting proxy. Every command below was run
as written and the expected output shown is what actually came back.

| Component | Verified version |
|---|---|
| Lab host | Ubuntu 24.04 (noble), kernel 7.0 |
| Docker / Compose / buildx | 29.1.3 / 2.40.3 / 0.30.1 (all from Ubuntu `universe`) |
| Toolbox and pqc-web OpenSSL | 3.5.8 (Fedora 43 system library) |
| legacy-web | nginx 1.20 on Alpine, OpenSSL 1.1.1 |
| nmap (in toolbox) | 7.92 |
| testssl.sh | 3.2.4 (`drwetter/testssl.sh` image) |
| SonarQube | Community Build 26.9.0 (`sonarqube:community`) |
| sonar-cryptography plugin | 1.6.1 |

---

## 1. Servers you actually need

| # | Name | What it is | Spec | Why |
|---|------|-----------|------|-----|
| 1 | **Lab host** | VM (VirtualBox, VMware, Hyper-V) | 6–8 vCPU, 16 GB RAM, 100 GB thin-provisioned disk, Ubuntu 24.04 LTS | Runs every container below. Real usage after a full build is ~20 GB |
| 2 | `pqc-web` | Container (Fedora 43 + nginx) | ~300 MB | Modern endpoint. Fedora 43 ships OpenSSL 3.5 as the system library, so ML-KEM works with no provider build |
| 3 | `legacy-web` | Container (nginx 1.20 / OpenSSL 1.1.1) | ~50 MB | The "before" picture: TLS 1.0–1.2, RSA-2048, SHA-1 cert |
| 4 | `toolbox` | Container (Fedora 43) | ~500 MB | Client, cert factory, nmap. Shares `/work` with the host |
| 5 | `sonarqube` | Container | 4 GB RAM, ~1 GB data for this lab | Hosts the sonar-cryptography plugin that emits `cbom.json` |
| 6 | **CTM** | Separate VM (OVA from Thales) | 4 vCPU, 8 GB RAM, 100 GB thin (confirm against 2.21 release notes) | ML-KEM key generation demo |
| 7 | **HSM** | DPoD Cloud HSM tenant, or physical Luna | no VM needed for DPoD | PQC firmware/client story |

**Thin-provision the virtual disk.** Declared size costs nothing; only written blocks
do. The 200 GB in older versions of this document was never needed.

### 1a. Grow the root filesystem if the installer left space unused

Ubuntu's installer often uses only part of the virtual disk. Check first:

```bash
lsblk
df -h /
```

If `sda` is bigger than the partition mounted on `/`, grow it online. No reboot.

```bash
sudo apt install -y cloud-guest-utils
# Ubuntu Desktop (no LVM): root is usually /dev/sda2
sudo growpart /dev/sda 2 && sudo resize2fs /dev/sda2
# Ubuntu Server (LVM): root is usually /dev/sda3 inside ubuntu-vg
# sudo growpart /dev/sda 3 && sudo pvresize /dev/sda3 \
#   && sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv \
#   && sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h /
```

### 1b. Host prep

**Do not skip this.** SonarQube will not start without the sysctl, and Compose
warns on every build without buildx.

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2 docker-buildx git jq
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
sudo usermod -aG docker "$USER"
newgrp docker            # or log out and back in
docker ps                # must print an empty table, not "permission denied"
```

### 1c. Behind a corporate TLS-inspecting proxy (Zscaler, Netskope, ...)

Symptom, on `docker compose build` or `docker pull`:

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

This happens on **any** network if the inspection client runs on the laptop that
hosts the VM: switching to a phone hotspot does not help. The CA has to be trusted
in two places: on the Ubuntu host (for pulls) and inside every image at build time
(for `dnf`/`apk`). The repo handles the second part; you do the first.

1. Find out who signs the intercepted certificates:

   ```bash
   openssl s_client -connect auth.docker.io:443 </dev/null 2>/dev/null | openssl x509 -noout -issuer
   ```

   If the issuer is your company or a proxy vendor rather than DigiCert or
   Let's Encrypt, continue.

2. Get the **full** CA chain up to the self-signed root. The proxy usually sends
   only the leaf and one intermediate, which is not enough for `dnf`. Export the
   chain from the corporate laptop's Windows trust store (`certmgr.msc`, or
   PowerShell `Get-ChildItem Cert:\LocalMachine\Root`), Base64/PEM, one file.

3. Drop it in the repo and trust it on the host:

   ```bash
   cp corp-ca.crt certs/corp-ca/                  # any *.crt name; folder is gitignored
   sudo cp certs/corp-ca/*.crt /usr/local/share/ca-certificates/
   sudo update-ca-certificates                    # "rehash: skipping" warnings are harmless
   sudo systemctl restart docker
   docker pull fedora:43                          # must succeed now
   ```

Every Dockerfile copies `certs/corp-ca/` and trusts whatever `*.crt` it finds before
its first package install, so the same file fixes the image builds. With no `*.crt`
present the builds behave exactly as before.

---

## 2. Bring the lab up

**Where:** lab host.

```bash
git clone https://github.com/Aadil-Nabi/pqc-al.git pqc-lab
cd pqc-lab

# If something on the host already listens on 9000 (MinIO does), pick another
# port for SonarQube. Put it in .env so it sticks; .env is gitignored.
echo 'SONAR_PORT=9900' > .env

docker compose build          # ~2 min on first run, ~1.5 GB of downloads
docker compose up -d          # pulls SonarQube (~1 GB), starts four containers
docker compose ps
```

All four must show `Up`. SonarQube takes about a minute to become ready.

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
  -connect legacy-web.lab:443 -groups X25519MLKEM768 -tls1_3 </dev/null 2>&1 \
  | grep -Ei "Cipher is|alert|error"
```

Expected:

```
OpenSSL 3.5.8 25 Aug 2026 (Library: OpenSSL 3.5.8 25 Aug 2026)
  X25519MLKEM768 @ default            (plus ML-KEM-512/768/1024 and the other hybrids)
  { ..., id-ml-dsa-65, ML-DSA-65, MLDSA65 } @ default
Negotiated TLS1.3 group: X25519MLKEM768
error:0A00042E:SSL routines:ssl3_read_bytes:tlsv1 alert protocol version
New, (NONE), Cipher is (NONE)
```

Do not judge the legacy check by `tail -5`: the last lines of `s_client` output
look the same on success and failure. Grep for the cipher and alert lines as above.

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
head -5 certs/estate/cert-inventory.csv
```

Takes about a minute. Expected tail (counts vary, the mix is random):

```
[*] Done. 201 certificates inventoried.
[*] Quick counts:
    117 RSA-2048
     42 prime256v1
     24 RSA-4096
     12 secp384r1
      5 RSA-1024
      1 ML-DSA-65
[*] SHA-1 signed:  33
[*] Already expired: 16
[*] Valid past 2030: 30
```

Fedora's system crypto policy refuses to *create* SHA-1 signatures. The script
handles that for the SHA-1 leaves with a one-off override config, and it reports
the failing line if anything else goes wrong. If it stops after "Issuing 200 leaf
certificates" with no error, you are running an old copy: `git pull`.

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

**Where:** lab host, not inside the toolbox (the script calls `docker` for testssl).

```bash
./scans/run-scans.sh
ls -la scans/out/
```

About two minutes. Outputs go to `scans/out/` — handshake transcripts, nmap cipher
enumeration, and full testssl.sh runs on both endpoints. What to look for:

- **Section 3** (legacy, TLS 1.3 forced): `tlsv1 alert protocol version`, `Cipher is (NONE)`.
- **Section 4** (legacy, TLS 1.2): `ECDHE-RSA-AES256-SHA`, a CBC suite.
- **Section 5** (nmap): legacy graded **F** with "Insecure certificate signature
  (SHA1)"; pqc-web graded **A**, TLS 1.3 only.
- **Section 6** (testssl 3.2.4): on pqc-web, the line `KEMs offered  X25519MLKEM768`
  and the browser-simulation table showing Chrome, Firefox, Edge and Android 15 all
  negotiating `X25519MLKEM768`. That table is a slide.

  ```bash
  grep -i -E "KEMs offered|MLKEM" scans/out/testssl-pqc-web.txt
  ```

**Say what the tools did not see.** The legacy nginx config asks for 3DES, but the
Alpine build of OpenSSL 1.1.1 has it compiled out, so neither nmap nor testssl lists
it. Do not claim 3DES in the room. If your testssl build ever fails to report ML-KEM,
say so out loud and fall back to `s_client`. Letting the team claim a tool sees
something it does not is the exact habit you are running this workshop to prevent.

---

## 5. Source-code CBOM

The CBOMkit toolset has moved between the IBM, PQCA and cbomkit GitHub
organisations. **Check the current canonical repo before you download anything** —
do not paste a URL from an old deck into a customer-facing artefact.

As of September 2026 the canonical repo is `github.com/cbomkit/sonar-cryptography`
(the IBM and PQCA URLs redirect there). Release 1.7.0 was tagged without a jar;
the newest release that ships one is 1.6.1. The compatibility table says SonarQube
9.9 LTS and up; **verified working on Community Build 26.9.0**, the current
`sonarqube:community` image.

The plugin covers Java (JCA, BouncyCastle), Python (pyca/cryptography) and Go, and
only the "Cryptographic Inventory (CBOM)" rule writes a `cbom.json`.

### 5a. Install the plugin

**Where:** lab host.

```bash
curl -L -O https://github.com/cbomkit/sonar-cryptography/releases/download/1.6.1/sonar-cryptography-plugin-1.6.1.jar
docker cp sonar-cryptography-plugin-1.6.1.jar sonarqube:/opt/sonarqube/extensions/plugins/
docker compose restart sonarqube
sleep 90
docker compose logs sonarqube | grep -i "crypto"
```

Expected: `Deploy Sonar Crypto Plugin / 1.6.1` and `Sonar Cryptography initialized`.
The jar is gitignored. The plugin lands in the `sonar_exts` volume, so it survives
`docker compose restart` and `up -d`, but not `down -v`.

### 5b. SonarQube UI, once

Open `http://<host>:9900` (or 9000 if you kept the default). Log in `admin`/`admin`
and set a new password.

1. **Create project.** Projects → Create → Local project. Name
   `Meridian BadCrypto Sample`. The UI turns that into the key
   `Meridian-BadCrypto-Sample`, which does **not** match
   `badcrypto/sonar-project.properties` — that is what `SONAR_PROJECT_KEY` below is
   for. Analysis method → **Locally** → generate a project token → copy it. Ignore
   the scanner instructions it shows; the script carries them.
2. **Plugin risk consent.** Administration → Marketplace
   (`http://<host>:9900/admin/marketplace`). If a banner asks you to accept the risk
   of non-SonarSource plugins, accept it. On 26.9 no banner appeared; the plugin
   simply shows as installed.
3. **Activate the CBOM rule, per language.** Quality profiles → filter **Java** →
   three-dot menu on **Sonar way** → **Copy** → name `Sonar way + CBOM`. On the new
   profile click **Activate More**, search `Cryptographic Inventory`, click
   **Activate** on "Cryptographic Inventory (CBOM)", keep the default severities.
   Back on Quality profiles, three-dot menu on `Sonar way + CBOM` → **Set as Default**.
   Repeat with the filter set to **Python**. Built-in profiles are read-only, hence
   the copy. The rule count goes from 599 to 600; that is your confirmation.

Without step 3 the scan reports `EXECUTION SUCCESS` and writes no CBOM.

### 5c. Run the scan

**Where:** lab host, repo root.

```bash
export SONAR_TOKEN=sqp_xxxxxxxx                    # project token from 5b
export SONAR_PROJECT_KEY=Meridian-BadCrypto-Sample # key SonarQube shows, not the properties file
./scans/cbom-scan.sh 2>&1 | grep -v 'constructor definition'   # hides ~400 harmless plugin INFO lines
ls -la badcrypto/cbom.json
```

First run pulls the Maven and sonar-scanner images (~1 GB). Expected tail:

```
CBOM was successfully generated '/usr/src/cbom.json'.
========== CBOM Statistics ==========
Detected Assets                  : 18
 - BlockCipher                   : 2
 - MessageDigest                 : 3
 - AuthenticatedEncryption       : 1
 - SecretKey                     : 5
 - PrivateKey                    : 3
 - Key                           : 3
 - Signature                     : 1
EXECUTION SUCCESS
```

If you get `You're not authorized to analyze this project or the project doesn't
exist`, the key or the token is wrong. List the real key:

```bash
curl -s -u admin:'<password>' "http://localhost:9900/api/projects/search" | jq '.components[] | {key, name}'
```

`badcrypto/` is a deliberately messy sample: MD5, SHA-1, DES/ECB, 3DES, a hardcoded
key and static IV, RSA-1024, RSA-2048, ECDSA P-256 — plus one correct AES-256-GCM
path so there is something to contrast against.

### 5d. Two views of the CBOM for the reconciliation exercise

```bash
# every algorithm with its primitive and OID
jq -r '.components[] | select(.cryptoProperties.assetType=="algorithm")
  | [.name, .cryptoProperties.algorithmProperties.primitive, .cryptoProperties.oid] | @tsv' \
  badcrypto/cbom.json | sort -u

# key material by type and size
jq -r '.components[] | select(.cryptoProperties.assetType=="related-crypto-material")
  | [.cryptoProperties.relatedCryptoMaterialProperties.type, .cryptoProperties.relatedCryptoMaterialProperties.size] | @tsv' \
  badcrypto/cbom.json | sort | uniq -c
```

Hand these two tables plus the certificate CSV to the team. Three things the
verified output contains that they should find on their own:

- **Missing OIDs.** 3DES-ECB, DES-56, MD5 and the bare EC key carry no `oid`. When a
  tool emits a name but no identifier, which controlled value goes in the workbook?
- **No quantum status.** Nothing in the CBOM says "Shor-broken". The tool inventories;
  the team classifies. RSA, ECDSA and EC keys are Shor-broken; MD5, SHA-1, DES and
  3DES are broken classically and are C4 regardless of quantum.
- **Key material with no size**, and RSA private keys labelled `secret-key`. Every
  such row is resolved by reading the source. Multiply by a bank's codebase and you
  have the effort estimate.

The one counterexample: AES-256-GCM with a 96-bit IV and 256-bit key is correct and
survives both a classical and a quantum review unchanged.

**The real exercise:** have someone reconcile ten `cbom.json` entries by hand against
the workbook register. Every mapping gap you find here is one you will not discover
in front of the customer.

### 5e. A second opinion (optional)

`cdxgen --include-crypto` produces a CBOM from Java keystores and certificates plus
JavaScript source with one command and no server. Run it on the same folder and
compare; two CBOMs that disagree make the reconciliation exercise sharper.

```bash
docker run --rm -v "$PWD/badcrypto":/app -w /app ghcr.io/cyclonedx/cdxgen:latest \
  --include-crypto -t java -o /app/cbom-cdxgen.json .
```

**Deployment artefacts, not just source.** `cbomkit-theia` is the complementary tool:
it finds certificates, keys, secrets and config inside container images rather than
API calls in code. Run it against one of your own images so the team sees the gap
between the two scans. Source scanning alone will miss most of a bank's estate.

Commercial platforms the customer may already own, all of which export CycloneDX
CBOM: Keyfactor AgileSec (ex-InfoSec Global), SandboxAQ AQtive Guard (ex-Cryptosense),
IBM Guardium Quantum Safe. If they have one, ask for the export and reconcile it the
same way. That is a faster Phase 1, not a different one.

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

## 7. Snapshot, housekeeping, teardown

**Snapshot the VM as soon as section 5 passes.** If a workshop attendee breaks
something on day 1, you want a ten-minute restore, not a rebuild. The images are
cached in the snapshot, so `docker compose up -d` works afterwards even on a network
that blocks Docker Hub.

**Before the workshop:** rotate the SonarQube project token and change the admin
password if either was ever pasted into a chat, a ticket or a deck (avatar → My
Account → Security). Make the GitHub repo private before any real engagement
material goes near it.

**Teardown:**

```bash
docker compose down -v          # drops SonarQube data and the plugin too
rm -rf certs/estate scans/out badcrypto/cbom.json badcrypto/target
```

---

## Troubleshooting (all seen during the verified build)

| Symptom | Cause | Fix |
|---|---|---|
| `x509: certificate signed by unknown authority` on pull or build | TLS-inspecting proxy on the laptop | Section 1c. Full chain to the root, on the host **and** in `certs/corp-ca/` |
| `./scans/run-scans.sh: Permission denied` | Old checkout before the exec bit was committed | `git pull`, or `bash scans/run-scans.sh` |
| `failed to bind host port 0.0.0.0:9000` | Something else (MinIO) owns 9000 | `echo 'SONAR_PORT=9900' > .env && docker compose up -d sonarqube` |
| `make-estate.sh` stops silently after "Issuing 200 leaf certificates" | Fedora policy blocks SHA-1 signing; old script had no error trap | `git pull`; the current script handles it |
| Scanner: `You're not authorized to analyze this project` | Project key in SonarQube differs from the properties file | `export SONAR_PROJECT_KEY=<key from the UI>` |
| Scan succeeds, no `cbom.json` | CBOM rule not active on the profile the project uses | Section 5b step 3, for **each** language |
| `Docker Compose is configured to build using Bake, but buildx isn't installed` | Missing package | `sudo apt install -y docker-buildx` |
| Legacy check with `tail -5` looks identical on success and failure | It is | Grep for `Cipher is`, `alert`, `error` |

---

## Build schedule

| When | What | Effort |
|------|------|--------|
| Day 1 | Host prep, proxy CA, `docker compose up`, section 2 checks pass | 3 hours |
| Day 1 | Certificate estate + inventory exercise dry run | 2 hours |
| Day 2 | Network scans, review the output yourself first | 2 hours |
| Day 2 | SonarQube plugin, CBOM scan, manual reconciliation | 4 hours |
| Day 3 | CTM and HSM, snapshot the host | 3 hours |

The verified build of sections 1–5, including finding every fix in the
troubleshooting table, took one working day. A clean rebuild from this runbook
should take under two hours.

Start the mock-customer pack in parallel on day 1. It takes longer to write than the
lab takes to build, and it matters more.
