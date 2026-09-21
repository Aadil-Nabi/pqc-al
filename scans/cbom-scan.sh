#!/usr/bin/env bash
# Source-code CBOM generation via SonarQube + sonar-cryptography.
# RUN ON THE LAB HOST after the plugin is installed and SonarQube restarted.
#
# Prereq once:
#   sysctl -w vm.max_map_count=262144
#   download the sonar-cryptography plugin jar, then:
#     docker cp sonar-cryptography-<ver>.jar sonarqube:/opt/sonarqube/extensions/plugins/
#     docker compose restart sonarqube
#   log in at http://<host>:9000 (admin/admin), change password,
#   create project "meridian-badcrypto", generate a token, export it:
#     export SONAR_TOKEN=squ_xxx
set -euo pipefail
: "${SONAR_TOKEN:?export SONAR_TOKEN first}"
# Project key must match the project in SonarQube. Override if you created it in the UI:
#   export SONAR_PROJECT_KEY=<key shown in SonarQube>
PROJECT_KEY="${SONAR_PROJECT_KEY:-meridian-badcrypto}"
NET=$(docker network ls --format '{{.Name}}' | grep -m1 'lab$')
SRC="$(cd "$(dirname "$0")/../badcrypto" && pwd)"

# Compile the Java so the scanner has bytecode. Skip if you only scan Python.
docker run --rm -v "$SRC":/src -w /src maven:3-eclipse-temurin-21 \
  sh -c 'mkdir -p target/classes && javac -d target/classes $(find src -name "*.java")' || true

docker run --rm --network "$NET" \
  -v "$SRC":/usr/src \
  -e SONAR_HOST_URL="http://sonarqube.lab:9000" \
  -e SONAR_TOKEN="$SONAR_TOKEN" \
  sonarsource/sonar-scanner-cli -Dsonar.projectKey="$PROJECT_KEY"

echo
echo "CBOM is written next to the scanned sources as cbom.json"
find "$SRC" -name 'cbom*.json' -print
echo
echo "Sanity check the output:"
echo "  jq '.components[] | {name, type, cryptoProperties}' $SRC/cbom.json | head -60"
