#!/usr/bin/env bash
#
# release.sh — drive a continuo blue/green release from CD.
#
# Manifests are already uploaded to S3 and the service images already pushed by
# the calling workflow. This script reaches release-controller's internal HTTP
# API (:8088, ClusterIP) — continuo has no public domain yet, so the only way in
# is SSH onto the Hetzner node and a server-side `kubectl port-forward`. Over
# that path it:
#   1. reads GET /current-prod — if current_prod is unseeded, this run is a
#      bootstrap (promote without validation);
#   2. POSTs the release (the controller replies 202 Accepted immediately);
#   3. polls GET /releases/<id> to a terminal status, failing on `rejected`.
#
# Connection model: each API call runs in its OWN short-lived SSH session that
# opens a one-shot port-forward, issues exactly one curl, and tears it down (see
# remote_api). We deliberately do NOT hold a single SSH tunnel open across the
# minutes-long poll: an idle tunnel gets reaped by NAT/firewall/sshd timeouts
# and, with no keepalive, the client hangs on the dead socket until it finally
# dies with `client_loop: send disconnect: Broken pipe`. Short, active sessions
# never sit idle long enough to be reaped. ServerAliveInterval is belt-and-
# suspenders for the few-second window each call is actually open.
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
#   POLL_ATTEMPTS    — terminal-status poll attempts (default 100). Each attempt
#                      is sleep + a short SSH round-trip (~5s), so ~100 attempts
#                      self-times-out at ~8-9m — just under the job's 10m cap, so
#                      a stuck release exits with a clean message rather than a
#                      hard job kill.
#   POLL_INTERVAL    — seconds between poll attempts (default 4)

set -euo pipefail

: "${HETZNER_HOST:?HETZNER_HOST must be set}"
: "${RELEASE_ID:?RELEASE_ID must be set}"
: "${SERVICE:?SERVICE must be set}"
: "${IMAGE_TAG:?IMAGE_TAG must be set}"
: "${REPO:?REPO must be set}"
: "${COMMIT_SHA:?COMMIT_SHA must be set}"
FWD_PORT="${FWD_PORT:-18088}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-100}"
POLL_INTERVAL="${POLL_INTERVAL:-4}"

SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=20
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
)

# remote_api METHOD PATH [BODY]
#
# One short-lived SSH session on continuo-server: open a one-shot kubectl
# port-forward to the release-controller ClusterIP, wait briefly for it to come
# up, issue exactly one curl, then let the EXIT trap tear the forward down. The
# heredoc is quoted ('REMOTE') so it ships literally; method/path/body/port are
# passed as the remote shell's environment, expanded only on the server.
#
# Prints the HTTP response body to stdout and returns curl's exit status (so the
# caller can distinguish a failed request from an empty body). The JSON we send
# contains no single quotes, so single-quoting it into the env is safe.
remote_api() {
  local method="$1" path="$2" body="${3:-}"
  ssh "${SSH_OPTS[@]}" "root@${HETZNER_HOST}" \
    "FWD_PORT='${FWD_PORT}' METHOD='${method}' API_PATH='${path}' BODY='${body}' bash -s" <<'REMOTE'
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl -n continuo port-forward svc/release-controller "${FWD_PORT}:8088" >/tmp/release-pf.log 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT

BASE="http://localhost:${FWD_PORT}"
# Wait for the forward to be ready (typically <1s); cap the wait so a wedged
# forward fails fast rather than hanging this session.
for _ in $(seq 1 30); do
  curl -sf "${BASE}/healthz" >/dev/null 2>&1 && break
  sleep 0.5
done

if [ -n "$BODY" ]; then
  curl -sf -X "$METHOD" "${BASE}${API_PATH}" -H 'content-type: application/json' -d "$BODY"
else
  curl -sf -X "$METHOD" "${BASE}${API_PATH}"
fi
REMOTE
}

echo "Driving release ${RELEASE_ID} (service=${SERVICE}, image_tag=${IMAGE_TAG}) against ${HETZNER_HOST}"

# Bootstrap detection: GET /current-prod returns current_prod_release_id="" when
# production has never been seeded. An empty id means this is the first release,
# which must bootstrap (promote without validation) — a normal release would be
# rejected because every cross-service upstream looks new against empty prod.
CURRENT="$(remote_api GET /current-prod || echo '{}')"
CUR_ID="$(printf '%s' "$CURRENT" | sed -n 's/.*"current_prod_release_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -z "$CUR_ID" ]; then BOOTSTRAP=true; else BOOTSTRAP=false; fi
echo "current_prod release_id='${CUR_ID}' -> bootstrap=${BOOTSTRAP}"

BODY="$(printf '{"release_id":"%s","service":"%s","image_tag":"%s","bootstrap":%s,"repo":"%s","commit_sha":"%s"}' \
  "$RELEASE_ID" "$SERVICE" "$IMAGE_TAG" "$BOOTSTRAP" "$REPO" "$COMMIT_SHA")"
echo "POST /releases ${BODY}"
remote_api POST /releases "$BODY" >/dev/null || { echo "POST /releases failed"; exit 1; }

# Poll to a terminal status; fail on rejection. Each poll is its own short-lived
# SSH session (see remote_api) — nothing is held open across the sleeps.
STATUS=""
for _ in $(seq 1 "$POLL_ATTEMPTS"); do
  REL="$(remote_api GET "/releases/${RELEASE_ID}" || true)"
  STATUS="$(printf '%s' "$REL" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  case "$STATUS" in
    promoted) echo "✅ release ${RELEASE_ID} promoted"; exit 0 ;;
    rejected) echo "❌ release ${RELEASE_ID} rejected:"; printf '%s\n' "$REL"; exit 1 ;;
  esac
  sleep "$POLL_INTERVAL"
done
echo "❌ timeout waiting for terminal status (last: ${STATUS:-unknown})"
exit 1
