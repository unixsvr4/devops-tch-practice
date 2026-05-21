#!/bin/bash
# Local SAST scan — SonarQube Community on Mac M1
# Run from repo root: bash sonarqube/scan.sh
#
# First run: ~2 min for SonarQube to start + DB to initialise.
# Subsequent runs: ~20s (containers already up).
#
# Scanner priority:
#   1. Native arm64 sonar-scanner (brew install sonar-scanner) — fastest
#   2. Docker sonar-scanner-cli (amd64, runs via Rosetta)      — no install needed

set -euo pipefail

SONAR_URL="http://localhost:9000"
PROJECT_KEY="tch-payment-app"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/sonarqube/docker-compose.yml"

# ── [1] Start SonarQube if not running ───────────────────────────────────────
if ! docker compose -f "$COMPOSE_FILE" ps -q sonarqube 2>/dev/null | grep -q .; then
    echo "[1/4] Starting SonarQube + Postgres..."
    docker compose -f "$COMPOSE_FILE" up -d
else
    echo "[1/4] SonarQube already running."
fi

# ── [2] Wait for SonarQube to be UP ─────────────────────────────────────────
echo "[2/4] Waiting for SonarQube to be ready (up to ~2 min on first start)..."
until curl -sf "$SONAR_URL/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; do
    sleep 5; printf '.'
done
echo " UP."

# ── Detect working admin credentials ─────────────────────────────────────────
# SonarQube 9.9 ships with admin:admin. The UI forces a password change on first
# browser login, but if you have never logged in via the UI it's still admin:admin.
SONAR_CREDS=""
for try_pass in "admin" "admin123" "sonar"; do
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${try_pass}" \
        "$SONAR_URL/api/authentication/validate")
    if [[ "$http_code" == "200" ]]; then
        SONAR_CREDS="admin:${try_pass}"
        break
    fi
done

if [[ -z "$SONAR_CREDS" ]]; then
    echo ""
    echo "ERROR: Could not authenticate to SonarQube with admin credentials."
    echo "If you changed the admin password via the browser UI, run:"
    echo "  SONAR_ADMIN_PASS=<your-password> bash sonarqube/scan.sh"
    echo ""
    echo "Or reset to defaults:"
    echo "  cd sonarqube && docker compose down -v && docker compose up -d"
    exit 1
fi

# Allow overriding creds via env var
if [[ -n "${SONAR_ADMIN_PASS:-}" ]]; then
    SONAR_CREDS="admin:${SONAR_ADMIN_PASS}"
fi

echo "  Authenticated as admin."

# ── [3] Create project + generate token ─────────────────────────────────────
echo "[3/4] Configuring project '$PROJECT_KEY'..."

curl -sf -u "$SONAR_CREDS" -X POST "$SONAR_URL/api/projects/create" \
    --data-urlencode "project=$PROJECT_KEY" \
    --data-urlencode "name=TCH Payment Service" \
    --data-urlencode "visibility=public" 2>/dev/null || true

# Generate a fresh scanner token and validate it is non-empty
TOKEN_JSON=$(curl -sf -u "$SONAR_CREDS" -X POST "$SONAR_URL/api/user_tokens/generate" \
    --data-urlencode "name=scan-$(date +%s)")

TOKEN=$(echo "$TOKEN_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['token'])" 2>/dev/null || true)

if [[ -z "$TOKEN" ]]; then
    echo ""
    echo "ERROR: Token generation failed. Raw API response:"
    echo "  $TOKEN_JSON"
    echo ""
    echo "Re-run with your admin password:"
    echo "  SONAR_ADMIN_PASS=<password> bash sonarqube/scan.sh"
    exit 1
fi

echo "  Token generated."

# ── [4] Run the scanner ──────────────────────────────────────────────────────
echo "[4/4] Scanning app/..."

if command -v sonar-scanner &>/dev/null; then
    echo "  Using native sonar-scanner (arm64)"
    # sonar.login is the correct property for SonarQube 9.9
    # (sonar.token was added in SonarQube 10.x)
    sonar-scanner \
        -Dsonar.host.url="$SONAR_URL" \
        -Dsonar.login="$TOKEN" \
        -Dsonar.projectKey="$PROJECT_KEY" \
        -Dsonar.projectName="TCH Payment Service" \
        -Dsonar.projectBaseDir="$REPO_ROOT/app" \
        -Dsonar.sources="." \
        -Dsonar.language=py \
        -Dsonar.python.version=3.12 \
        -Dsonar.exclusions="**/__pycache__/**,**/*.pyc"
else
    echo "  Using sonar-scanner-cli via Docker (amd64/Rosetta)"
    echo "  Tip: brew install sonar-scanner  ← gets native arm64"
    docker run --rm \
        -v "$REPO_ROOT/app:/usr/src" \
        -v "$REPO_ROOT/sonarqube/sonar-project.properties:/usr/src/sonar-project.properties:ro" \
        -e SONAR_HOST_URL="http://host.docker.internal:9000" \
        -e SONAR_TOKEN="$TOKEN" \
        sonarsource/sonar-scanner-cli:latest
fi

echo ""
echo "Scan complete."
echo "Results  → $SONAR_URL/dashboard?id=$PROJECT_KEY"
echo "Login    → ${SONAR_CREDS%%:*} / ${SONAR_CREDS##*:}"
echo ""
echo "Quality Gate status:"
sleep 5
curl -sf -u "$SONAR_CREDS" \
    "$SONAR_URL/api/qualitygates/project_status?projectKey=$PROJECT_KEY" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
status = d['projectStatus']['status']
icon = '✓' if status == 'OK' else '✗'
print(f'  {icon} Quality Gate: {status}')
for c in d['projectStatus'].get('conditions', []):
    if c['status'] != 'OK':
        print(f\"    FAILED: {c['metricKey']} = {c['actualValue']} (threshold: {c['errorThreshold']})\")
" 2>/dev/null || echo "  (gate result not yet available — check the UI)"
echo ""
echo "Talking point: in CI, SONAR_TOKEN is a GitHub secret."
echo "sonar.qualitygate.wait=true blocks the build if the Quality Gate fails."
