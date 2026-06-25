# continuo-dbt-demo

A reference **dbt producer** for [continuo](https://github.com/carolsimone/continuo)'s blue/green release pipeline. It owns several dbt services, builds their images, and drives a continuo release from CD — the worked example of how any consumer's CD integrates with continuo.

## Reference implementation of the public "loading releases" interface

This repo is the **reference external integration** for continuo's public release-loading contract. It is a deliberate, independent reimplementation of that contract: it shares **no code** with continuo internals — no Go packages, no shared client library. Everything here (the manifest filtering, the canonical S3 key, the `POST /releases` body, the bootstrap detection) is rebuilt from the contract alone. That duplication is the point: it proves the contract is self-describing enough for an outside team to integrate against without reading continuo's source.

The authoritative contract is documented in continuo:
**[docs/integration/loading-releases.md](https://github.com/carolsimone/continuo/blob/main/docs/integration/loading-releases.md)**.

If this README and that document ever disagree, the continuo doc is authoritative — open an issue against continuo or this repo.

## What it does

On every push to `services/**` (or manual dispatch), `.github/workflows/release.yml`:

1. **Builds + pushes** the shared `dbt-base` image and **the one changed service's** image to Docker Hub as `<DOCKERHUB_USERNAME>/<service>:<short-sha>` (+ `:latest`). The name/tag is the contract: continuo's executor launches dbt jobs as `<DOCKERHUB_USERNAME>/<service_name>:<image_tag>`. Only the changed service gets a new image; the other services keep their current prod tags (continuo reuses them via its `service_prod` pointers).

   **Base-change fan-out.** When a push changes `dbt-base/**` (the shared `dbt-base` — e.g. `validation_runner.py` or a shared macro), the one-changed-service rule isn't enough: every *other* service still runs from an image built on the **old** base, and since a changed-node validation spans the full cross-service closure (service-2/service-3 form a cycle), those stale-base images make releases reject at `validating` with no way to self-heal. So on any `dbt-base/**` change the workflow runs `scripts/rebuild_services_from_base.sh`, which re-bakes **every** service image FROM the fresh base and re-pushes it under the tag continuo's prod pointers already reference — the short SHA of the last commit that touched each `services/<svc>/`. No `service_prod` pointer moves; combined with the validation Job's `imagePullPolicy: Always`, every validation and run then re-pulls the fresh base. A base-only push (no service changed) runs just this fan-out and posts no release.
2. **Compiles** the changed service (`dbt compile` against an ephemeral Postgres — no data needed, compile only resolves refs/jinja into `manifest.json`) and **uploads** its manifest to the Hetzner object store at the canonical key `<service>/<release_id>/manifest.json` (via `dbt_load`, `hetzner` target in `targets.yaml`). The manifest is filtered before upload: only `model` and `seed` nodes are kept, and any node tagged `local_stub` is dropped. The image tag is **not** stored in S3.
3. **Drives the release** (`scripts/release.sh`): SSHes to `continuo-server`, port-forwards the internal `release-controller` ClusterIP (`:8088`), reads `GET /current-prod`, then `POST /releases` and **polls to a terminal status — failing the deploy on `rejected`**.

### The release contract (what `scripts/release.sh` sends)

continuo models a release as a **single changed service**. The request body is:

```json
{"release_id": "rel-<sha>-<run>", "service": "service-3", "image_tag": "<sha>", "bootstrap": false, "repo": "<owner>/<repo>", "commit_sha": "<full-sha>"}
```

- `service` and `image_tag` are **single values**, not maps. `repo` and `commit_sha` identify the source push (`github.repository` / `github.sha`). There is **no `manifests_uri`** in the body — the controller derives the S3 key itself from `bucket + service + release_id` (continuo's `CanonicalManifestKey`). There is **no `service_metadata.json` sidecar**; the image tag travels in this body, not in S3.
- The controller replies `202 Accepted` with `{"release_id": "...", "status": "received"}`.
- The script then polls `GET /releases/<release_id>` until `status` is terminal: `promoted` (success) or `rejected` (failure). The other services' manifests are already in S3 from their own releases; the controller reconstructs the full set via the live `service_prod` pointers.

### Connection model

continuo's release API has no public domain yet — it is an internal `ClusterIP` on `:8088`. The only way in is SSH onto the Hetzner node and a server-side `kubectl port-forward`. Each API call (`/current-prod`, `POST /releases`, each poll) runs in its **own** short-lived SSH session that opens a one-shot port-forward, issues exactly one `curl`, and tears it down — a single long-held tunnel would be reaped by NAT/firewall/sshd idle timeouts during the minutes-long poll.

### First run = bootstrap

`release.sh` sets `bootstrap:true` automatically when `GET /current-prod` reports no current release (`current_prod_release_id` empty). A bootstrap release **promotes without validation** — necessary because, against an empty `current_prod`, normal validation rejects every cross-service upstream as new. Every subsequent run posts `bootstrap:false` and goes through validation. (Bootstrap promotes whatever topology it carries, so the first push must be a trusted one.)

## Repo layout

```
dbt-base/        # the dbt-base runtime image: dbt_base/ (validation_runner + result/seed wrappers),
                 #   macros/ (generate_schema_name), Dockerfile, tests/ (unit) — image name: dbt-base
services/        # one directory per dbt service: dbt_project.yml, profiles.yml (schema: analytics),
                 #   models/, seeds/, Dockerfile (FROM <user>/dbt-base:latest)
dbt-loader/      # the dbt_load library: compile + filter + upload-manifest-to-S3 CLI
                 #   (compile / upload / load); its own pyproject/uv.lock + targets.yaml,
                 #   tests/ (unit), integration/ (real dbt+S3), Dockerfile, docker-compose.test.yml
scripts/         # repo CD/utility tooling: release.sh, rebuild_services_from_base.sh,
                 #   gen_fx_rates_eur.py, tests/ (rebuild-script unit tests), pyproject.toml
.github/workflows/   # release.yml (deploy) + ci.yml (tests)
```

The services fall into two groups. `core`, `finance`, and `marketing` are clean example workloads. `service-1`, `service-2`, and `service-3` are copied from continuo's e2e fixtures and include failure-demo models: the `ftable_*` models (tagged `e2e-schedule-failure`) read cross-service tables straight out of the shared `analytics` schema rather than via `ref()`, forming the service-2/service-3 cycle noted above. Run in isolation, an upstream table isn't there yet, so they fail at run time — which is exactly what continuo uses to exercise failure paths and demo the reject path. All services materialize into the **`analytics`** schema (set in each `profiles.yml`).

## Required CI secrets

Configure these in the repo's Actions secrets before the workflow can run:

| Secret | Purpose |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub user; **must match** the username continuo's executor uses to pull job images, and the `FROM <user>/dbt-base` in the service Dockerfiles. |
| `DOCKERHUB_TOKEN` | Docker Hub push token. |
| `HETZNER_S3_ACCESS_KEY_ID` / `HETZNER_S3_SECRET_ACCESS_KEY` | Hetzner object-storage credentials (the `continuo-dev` bucket). |
| `HETZNER_HOST` | `continuo-server` host/IP (SSH as root). |
| `HETZNER_SSH_KEY` | Private SSH key authorized on the server (same key continuo's own deploy uses). |

## Local checks

```bash
# Library (dbt_load) unit tests — no external services:
cd dbt-loader && uv sync --frozen --extra dev && uv run pytest tests/

# Library integration tests (real dbt compile + S3) via docker compose:
docker build -t dbt-base:latest dbt-base/
docker compose -f dbt-loader/docker-compose.test.yml up --build --abort-on-container-exit --exit-code-from tests

# dbt-base runtime unit tests — no external services:
cd dbt-base && uv sync --frozen --extra dev && uv run pytest tests/

# scripts/ rebuild-script unit tests — no external services:
cd scripts && uv sync --frozen --extra dev && uv run pytest tests/

shellcheck scripts/release.sh
```

The integration tests in `dbt-loader/integration/test_upload.py` exercise real `dbt compile` and S3 uploads and run via the compose stack above (localstack + Postgres + the `dbt-base`-derived tool image). The CLI, config, compile-wrapper, and per-release upload-layout tests in `dbt-loader/tests/` run without any external services. The `dbt-base` validation-runner tests live in `dbt-base/tests/`, and the rebuild-script tests in `scripts/tests/` — each component owns its own tests (there is no repo-root `tests/`).
