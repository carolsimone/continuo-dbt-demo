#!/usr/bin/env bash
#
# rebuild_services_from_base.sh — re-bake every dbt service image FROM the
# current dbt-base and re-push it under the tag continuo's prod pointers already
# reference.
#
# Why: a change to dbt-base (base/**, e.g. validation_runner.py or a shared
# macro) only takes effect for a service once that service's image is rebuilt
# FROM the new base. The normal release path rebuilds ONLY the one changed
# service, so a base change leaves every other service on a stale-base image.
# Because a changed-node release validates the full cross-service closure (and
# service-2/service-3 form a dependency cycle), any release whose closure touches
# a stale-base service rejects at `validating` — and the pipeline cannot
# self-heal, as there is no single-service release whose closure stays within
# already-fresh services.
#
# This fan-out re-bakes ALL services FROM the fresh base under their EXISTING
# prod tags, so continuo's service_prod pointers keep resolving — now to
# fresh-base images. Combined with the validation Job's imagePullPolicy: Always,
# every validation (and prod run) re-pulls the fresh runner. No pointer changes
# and no extra release are needed.
#
# Each service's current prod tag is the short SHA of the last commit that
# touched its services/<svc>/ directory — exactly the tag release.yml assigned
# when that service was last released. We re-push that same tag plus :latest.
# (This requires full git history; the release job checks out with fetch-depth 0.)
#
# Required env:
#   DOCKERHUB_USERNAME — Docker Hub user (image namespace; must match the
#                        FROM <user>/dbt-base in each service Dockerfile and the
#                        username continuo's executor pulls job images with).
# Optional env:
#   DRY_RUN=1          — print the build plan ("<service> <tag>" per line) and
#                        exit without invoking docker. Used by the unit test.
#   SERVICES_DIR       — services root (default: services).
#   PLATFORM           — buildx --platform (default: linux/amd64, the k3s node arch).

set -euo pipefail

SERVICES_DIR="${SERVICES_DIR:-services}"
PLATFORM="${PLATFORM:-linux/amd64}"
DRY_RUN="${DRY_RUN:-}"

if [ -z "${DRY_RUN}" ]; then
  : "${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME must be set}"
fi

# A service is any immediate subdirectory of SERVICES_DIR that holds a Dockerfile.
# The glob expands in sorted order, giving a deterministic build plan.
services=()
for dir in "${SERVICES_DIR}"/*/; do
  [ -f "${dir}Dockerfile" ] || continue
  services+=("$(basename "${dir}")")
done

if [ "${#services[@]}" -eq 0 ]; then
  echo "::error::no services with a Dockerfile under ${SERVICES_DIR}" >&2
  exit 1
fi

for svc in "${services[@]}"; do
  # The tag prod already points at: the last commit that touched this service's
  # directory. Re-pushing this exact tag keeps service_prod pointers valid while
  # swapping in the fresh-base image underneath.
  tag="$(git log -1 --format=%h -- "${SERVICES_DIR}/${svc}")"
  if [ -z "${tag}" ]; then
    echo "::error::no commit history for ${SERVICES_DIR}/${svc}; cannot derive its prod tag" >&2
    exit 1
  fi

  if [ -n "${DRY_RUN}" ]; then
    printf '%s %s\n' "${svc}" "${tag}"
    continue
  fi

  echo "Re-baking ${svc} FROM fresh dbt-base -> ${DOCKERHUB_USERNAME}/${svc}:${tag} (+ :latest)"
  # --pull forces resolving dbt-base:latest from the registry (the fresh image
  # just pushed) rather than any cached base layer — the whole point is to bake
  # in the new base.
  docker buildx build \
    --push \
    --pull \
    --platform "${PLATFORM}" \
    -t "${DOCKERHUB_USERNAME}/${svc}:${tag}" \
    -t "${DOCKERHUB_USERNAME}/${svc}:latest" \
    --cache-from "type=gha,scope=${svc}" \
    --cache-to "type=gha,mode=max,scope=${svc}" \
    "${SERVICES_DIR}/${svc}"
done
