#!/usr/bin/env bash
# Build a mock certificate estate for the PQC assessment workshop.
# RUN INSIDE THE toolbox CONTAINER (needs OpenSSL 3.5+ for ML-DSA).
#   docker compose exec toolbox bash /work/certs/make-estate.sh 200
set -euo pipefail
trap 'echo "!! make-estate.sh failed at line $LINENO (command: $BASH_COMMAND)" >&2' ERR

COUNT="${1:-200}"
OUT="/work/certs/estate"
LEAF="$OUT/leaf"
INV="$OUT/cert-inventory.csv"

rm -rf "$OUT"; mkdir -p "$LEAF"
cd "$OUT"

echo "[*] OpenSSL: $(openssl version)"

# Fedora's system crypto policy refuses to *create* SHA-1 signatures
# (rh-allow-sha1-signatures = no). We want a few SHA-1 certs in the estate on
# purpose, so the SHA-1 signing step alone runs with this override config.
SHA1_CNF="$OUT/allow-sha1.cnf"
cat > "$SHA1_CNF" <<'CNF'
openssl_conf = openssl_init
[openssl_init]
alg_section = evp_properties
[evp_properties]
rh-allow-sha1-signatures = yes
CNF
openssl list -signature-algorithms | grep -qi 'ML-DSA' \
  || { echo "!! No ML-DSA. You are not on OpenSSL 3.5+. Stop and fix that first."; exit 1; }

echo "[*] Classical root CA (RSA-4096 / SHA-256)"
openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
  -keyout ca.key -out ca.crt \
  -subj "/C=SG/O=Meridian Bank/OU=PKI/CN=Meridian Internal Root CA" 2>/dev/null

echo "[*] PQC pilot root CA (ML-DSA-65) - private CA only, no public CA issues these"
openssl genpkey -algorithm ML-DSA-65 -out mldsa-ca.key 2>/dev/null
openssl req -x509 -key mldsa-ca.key -days 365 -out mldsa-ca.crt \
  -subj "/C=SG/O=Meridian Bank/OU=PKI/CN=Meridian PQC Pilot Root CA" 2>/dev/null

APPS=(ibanking corebank payments-gw swift-adapter mq-broker etl-batch \
      api-gw crm intranet vpn-gw ldap syslog backup mail print)
ENVS=(prod uat dev dr)

now=$(date -u +%s)
stamp() { date -u -d "@$1" +%Y%m%d%H%M%SZ; }

echo "[*] Issuing $COUNT leaf certificates"
for i in $(seq -w 1 "$COUNT"); do
  app=${APPS[$((RANDOM % ${#APPS[@]}))]}
  env=${ENVS[$((RANDOM % ${#ENVS[@]}))]}
  cn="${app}-${i}.${env}.meridian.sg"
  k="$LEAF/$cn.key"; c="$LEAF/$cn.crt"

  # Weighted key-algorithm mix: mostly RSA-2048, some ECDSA, a little RSA-4096,
  # plus a handful of weak RSA-1024 to give the team something to flag.
  r=$((RANDOM % 100))
  if   [ $r -lt 55 ]; then openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$k" 2>/dev/null
  elif [ $r -lt 75 ]; then openssl genpkey -algorithm EC  -pkeyopt ec_paramgen_curve:P-256 -out "$k" 2>/dev/null
  elif [ $r -lt 88 ]; then openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$k" 2>/dev/null
  elif [ $r -lt 95 ]; then openssl genpkey -algorithm EC  -pkeyopt ec_paramgen_curve:P-384 -out "$k" 2>/dev/null
  else                     openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 -out "$k" 2>/dev/null
  fi

  # Validity mix: live, expiring soon, long-dated (the agility problem), expired.
  v=$((RANDOM % 100))
  if   [ $v -lt 60 ]; then nb=$((now - 86400*200));  na=$((now + 86400*165))
  elif [ $v -lt 75 ]; then nb=$((now - 86400*350));  na=$((now + 86400*20))
  elif [ $v -lt 90 ]; then nb=$((now - 86400*400));  na=$((now + 86400*3000))
  else                     nb=$((now - 86400*800));  na=$((now - 86400*40))
  fi

  openssl req -new -key "$k" -subj "/C=SG/O=Meridian Bank/OU=$env/CN=$cn" -out "$LEAF/$cn.csr" 2>/dev/null

  # ~15% signed with SHA-1 to seed a Grover/collision talking point.
  if [ $((RANDOM % 100)) -lt 15 ]; then md="-sha1"; cnf="$SHA1_CNF"; else md="-sha256"; cnf=""; fi

  OPENSSL_CONF="$cnf" openssl x509 -req -in "$LEAF/$cn.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    $md -not_before "$(stamp $nb)" -not_after "$(stamp $na)" -out "$c" 2>/dev/null
  rm -f "$LEAF/$cn.csr"
done

# One ML-DSA leaf off the PQC pilot CA, for the inventory to pick up.
openssl genpkey -algorithm ML-DSA-65 -out "$LEAF/pqc-pilot.prod.meridian.sg.key" 2>/dev/null
openssl req -new -key "$LEAF/pqc-pilot.prod.meridian.sg.key" \
  -subj "/C=SG/O=Meridian Bank/OU=prod/CN=pqc-pilot.prod.meridian.sg" \
  -out "$LEAF/pqc.csr" 2>/dev/null
openssl x509 -req -in "$LEAF/pqc.csr" -CA mldsa-ca.crt -CAkey mldsa-ca.key -CAcreateserial \
  -days 180 -out "$LEAF/pqc-pilot.prod.meridian.sg.crt" 2>/dev/null
rm -f "$LEAF/pqc.csr"

echo "[*] Writing inventory: $INV"
# Column names deliberately shaped toward CycloneDX 1.6 cryptographic-asset fields.
echo "common_name,environment,application,assetType,primitive,parameterSetIdentifier,keySize_bits,signatureAlgorithm,notBefore,notAfter,days_remaining,quantum_status" > "$INV"

for c in "$LEAF"/*.crt; do
  txt=$(openssl x509 -in "$c" -noout -text)
  cn=$(openssl x509 -in "$c" -noout -subject -nameopt RFC2253 | sed 's/.*CN=//; s/,.*//')
  env=$(openssl x509 -in "$c" -noout -subject -nameopt RFC2253 | sed -n 's/.*OU=\([^,]*\).*/\1/p')
  app=$(echo "$cn" | sed -E 's/-[0-9]+\..*$//; s/\..*$//')   # api-gw-042.prod.x -> api-gw ; pqc-pilot.prod.x -> pqc-pilot
  keyalg=$(echo "$txt" | awk -F': ' '/Public Key Algorithm:/{print $2; exit}')
  bits=$(echo "$txt"   | sed -n 's/.*Public-Key: (\([0-9]*\) bit).*/\1/p' | head -1)
  curve=$(echo "$txt"  | awk -F': ' '/ASN1 OID:/{print $2; exit}')
  sigalg=$(echo "$txt" | awk -F': ' '/Signature Algorithm:/{print $2; exit}')
  nb=$(openssl x509 -in "$c" -noout -startdate | cut -d= -f2)
  na=$(openssl x509 -in "$c" -noout -enddate   | cut -d= -f2)
  rem=$(( ( $(date -u -d "$na" +%s) - now ) / 86400 ))

  case "$keyalg" in
    rsaEncryption)   prim="pke"; param="RSA-${bits}" ;;
    id-ecPublicKey)  prim="signature"; param="${curve:-EC}" ;;
    ML-DSA-65)       prim="signature"; param="ML-DSA-65" ;;
    *)               prim="unknown"; param="${keyalg}" ;;
  esac

  case "$keyalg" in
    rsaEncryption|id-ecPublicKey) qs="Shor-broken" ;;
    ML-DSA*)                      qs="quantum-safe" ;;
    *)                            qs="review" ;;
  esac

  echo "$cn,$env,$app,certificate,$prim,$param,${bits:-na},$sigalg,$nb,$na,$rem,$qs" >> "$INV"
done

echo
echo "[*] Done. $(( $(wc -l < "$INV") - 1 )) certificates inventoried."
echo "[*] Quick counts:"
tail -n +2 "$INV" | awk -F, '{print $6}' | sort | uniq -c | sort -rn
echo "[*] SHA-1 signed:  $(tail -n +2 "$INV" | grep -ci 'sha1')"
echo "[*] Already expired: $(tail -n +2 "$INV" | awk -F, '$11 < 0' | wc -l)"
echo "[*] Valid past 2030: $(tail -n +2 "$INV" | awk -F, '$11 > 1560' | wc -l)"
