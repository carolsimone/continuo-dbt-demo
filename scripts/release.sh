#!/usr/bin/env bash
#
# release.sh — drive a continuo blue/green release from CD.
#
# Manifests are already uploaded to S3 and the service images already pushed by
# the calling workflow. This script crosses into the Hetzner cluster over SSH,
# reaches release-controller's internal HTTP API (:8088, ClusterIP) via a
# server-side `kubectl port-forward`, and:
#   1. reads GET /current-prod — if current_prod is unseeded, this run is a
#      bootstrap (promote without validation);
#   2. POSTs the release;
#   3. polls GET /releases/<id> to a terminal status, failing the deploy on
#      `rejected`.
#
# The port-forward + curl run ON the server (where the ClusterIP service is
# reachable on localhost). The runner only needs SSH access.
#
# continuo models a release as a SINGLE changed service: POST /releases takes
# one {service, image_tag} and the controller reconstructs the full manifest set
# from the live service_prod pointers. The changed service's manifest is already
# in S3 at the canonical key <service>/<release_id>/manifest.json, which the
# controller derives itself — so it is not sent in the body.
#
# Required environment:
#   HETZNER_HOST     — server host/IP (SSH as root; key already in ~/.ssh)
#   RELEASE_ID       — unique per run, e.g. rel-<shortsha>-<runid>
#   SERVICE          — the single changed service, e.g. service-3
#   IMAGE_TAG        — that service's image tag (this commit's short sha)
#
# Optional:
#   FWD_PORT         — server-local port for the forward (default 18088)
#   POLL_ATTEMPTS    — terminal-status poll attempts (default 150 × 4s = 10m)

set -euo pipefail

: "${HETZNER_HOST:?HETZNER_HOST must be set}"
: "${RELEASE_ID:?RELEASE_ID must be set}"
: "${SERVICE:?SERVICE must be set}"
: "${IMAGE_TAG:?IMAGE_TAG must be set}"
FWD_PORT="${FWD_PORT:-18088}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-150}"

echo "Driving release ${RELEASE_ID} against ${HETZNER_HOST}"

# The remote script runs on continuo-server. Its positional args ($1..$4) carry
# the release fields; the heredoc body is quoted ('REMOTE') so it is sent
# literally and expanded only on the server.
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
  "root@${HETZNER_HOST}" \
  "bash -s '${RELEASE_ID}' '${SERVICE}' '${IMAGE_TAG}' '${FWD_PORT}' '${POLL_ATTEMPTS}'" <<'REMOTE'
set -euo pipefail
RELEASE_ID="$1"; SERVICE="$2"; IMAGE_TAG="$3"; FWD_PORT="$4"; POLL_ATTEMPTS="$5"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl -n continuo port-forward svc/release-controller "${FWD_PORT}:8088" >/tmp/release-pf.log 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT

BASE="http://localhost:${FWD_PORT}"
for _ in $(seq 1 30); do
  curl -sf "${BASE}/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "${BASE}/healthz" >/dev/null 2>&1 || { echo "release-controller unreachable via port-forward"; cat /tmp/release-pf.log; exit 1; }

# Bootstrap detection: GET /current-prod returns current_prod_release_id="" when
# production has never been seeded. An empty id means this is the first release,
# which must bootstrap (promote without validation) — a normal release would be
# rejected because every cross-service upstream looks new against empty prod.
CURRENT=$(curl -sf "${BASE}/current-prod" || echo '{}')
CUR_ID=$(printf '%s' "$CURRENT" | sed -n 's/.*"current_prod_release_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "$CUR_ID" ]; then BOOTSTRAP=true; else BOOTSTRAP=false; fi
echo "current_prod release_id='${CUR_ID}' -> bootstrap=${BOOTSTRAP}"

BODY=$(printf '{"release_id":"%s","service":"%s","image_tag":"%s","bootstrap":%s}' \
  "$RELEASE_ID" "$SERVICE" "$IMAGE_TAG" "$BOOTSTRAP")
echo "POST ${BASE}/releases ${BODY}"
curl -sf -X POST "${BASE}/releases" -H 'content-type: application/json' -d "$BODY" || { echo "POST /releases failed"; exit 1; }
echo

# Poll to a terminal status; fail on rejection.
STATUS=""
for _ in $(seq 1 "$POLL_ATTEMPTS"); do
  REL=$(curl -sf "${BASE}/releases/${RELEASE_ID}" || true)
  STATUS=$(printf '%s' "$REL" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  case "$STATUS" in
    promoted) echo "✅ release ${RELEASE_ID} promoted"; exit 0 ;;
    rejected) echo "❌ release ${RELEASE_ID} rejected:"; printf '%s\n' "$REL"; exit 1 ;;
  esac
  sleep 4
done
echo "❌ timeout waiting for terminal status (last: ${STATUS:-unknown})"
exit 1
REMOTE
