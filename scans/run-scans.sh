#!/usr/bin/env bash
# Network-layer discovery against both endpoints.
# RUN ON THE LAB HOST (not inside toolbox) - it calls docker for testssl.
set -uo pipefail

OUT="$(cd "$(dirname "$0")" && pwd)/out"
mkdir -p "$OUT"
NET=$(docker network ls --format '{{.Name}}' | grep -m1 'lab$')

echo "=============================================================="
echo " 1. Does the client even speak PQC?"
echo "=============================================================="
docker compose exec -T toolbox openssl version
docker compose exec -T toolbox openssl list -kem-algorithms       | grep -i mlkem
docker compose exec -T toolbox openssl list -signature-algorithms | grep -iE 'ml-dsa|slh-dsa'

echo
echo "=============================================================="
echo " 2. Modern endpoint - expect a negotiated hybrid group"
echo "=============================================================="
docker compose exec -T toolbox sh -c \
  "openssl s_client -connect pqc-web.lab:443 -groups X25519MLKEM768 -tls1_3 </dev/null 2>&1 | grep -Ei 'Negotiated|Protocol|Cipher|Peer sig'" \
  | tee "$OUT/pqc-handshake.txt"

echo
echo "=============================================================="
echo " 3. Legacy endpoint - expect this to FAIL. That failure is the lesson."
echo "=============================================================="
docker compose exec -T toolbox sh -c \
  "openssl s_client -connect legacy-web.lab:443 -groups X25519MLKEM768 -tls1_3 </dev/null 2>&1 | grep -Ei 'Cipher is|alert|error'" \
  | tee "$OUT/legacy-handshake-fail.txt"

echo
echo "=============================================================="
echo " 4. What the legacy endpoint actually accepts"
echo "=============================================================="
docker compose exec -T toolbox sh -c \
  "openssl s_client -connect legacy-web.lab:443 -tls1_2 </dev/null 2>&1 | grep -Ei 'Protocol|Cipher|Signature'" \
  | tee "$OUT/legacy-handshake-tls12.txt"

echo
echo "=============================================================="
echo " 5. nmap cipher enumeration"
echo "=============================================================="
docker compose exec -T toolbox nmap --script ssl-enum-ciphers -p 443 legacy-web.lab \
  | tee "$OUT/nmap-legacy.txt"
docker compose exec -T toolbox nmap --script ssl-enum-ciphers -p 443 pqc-web.lab \
  | tee "$OUT/nmap-pqc.txt"

echo
echo "=============================================================="
echo " 6. testssl.sh full run on both"
echo "=============================================================="
for h in legacy-web pqc-web; do
  docker run --rm --network "$NET" drwetter/testssl.sh \
    --color 0 --full "https://${h}.lab:443" > "$OUT/testssl-${h}.txt" 2>&1
  echo "  -> $OUT/testssl-${h}.txt"
done

echo
echo "Artefacts in $OUT"
ls -1 "$OUT"
echo
echo "NOTE: check whether your testssl build reports ML-KEM groups."
echo "      If it does not, say so in the workshop and fall back to s_client."
echo "      Do not let the team claim a tool sees something it does not."
