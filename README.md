# continuo-dbt-demo

A reference **dbt producer** for [continuo](https://github.com/carolsimone/continuo)'s blue/green release pipeline. It owns three dbt services, builds their images, and drives a continuo release from CD — the worked example of how any consumer's CD integrates with continuo.

## What it does

On every push to `services/**` (or manual dispatch), `.github/workflows/release.yml`:

1. **Builds + pushes** the shared `dbt-base` image and the three service images to Docker Hub as `<DOCKERHUB_USERNAME>/service-{1,2,3}:<short-sha>` (+ `:latest`). The name/tag is the contract: continuo's executor launches dbt jobs as `<DOCKERHUB_USERNAME>/<service_name>:<image_tag>`.
2. **Compiles** each service (`dbt compile` against an ephemeral Postgres — no data needed) and **uploads** the manifests to the Hetzner object store at `releases/<release_id>/manifests/<service>/manifest_v1.json` (via `dbt_upload`, `hetzner` target in `targets.yaml`).
3. **Drives the release** (`scripts/release.sh`): SSHes to `continuo-server`, port-forwards `release-controller` (:8088), reads `GET /current-prod`, then `POST /releases` with `{release_id, manifests_uri, image_tags, bootstrap}` and **polls to a terminal status — failing the deploy on `rejected`**.

`image_tags` travel in the POST body (continuo treats them as authoritative); there is **no `service_metadata.json` sidecar** dependency.

### First run = bootstrap

`release.sh` sets `bootstrap:true` automatically when `GET /current-prod` reports no current release (`current_prod_release_id` empty). A bootstrap release **promotes without validation** — necessary because, against an empty `current_prod`, normal validation rejects every cross-service upstream as new. Every subsequent run posts `bootstrap:false` and goes through validation. (Bootstrap promotes whatever topology it carries, so the first push must be a trusted one.)

## Repo layout

```
base/            # dbt-base image: pinned dbt-core/dbt-postgres + shared macros (generate_schema_name)
services/        # service-1/2/3: dbt_project.yml, profiles.yml (schema: analytics), models/, seeds/, Dockerfile
dbt_upload/      # compile + upload-to-S3 CLI
targets.yaml     # S3 targets (hetzner → continuo-dev bucket)
Dockerfile.upload, pyproject.toml, uv.lock, tests/   # dbt_upload packaging + its tests
scripts/release.sh
.github/workflows/release.yml
```

The models are copied from continuo's e2e fixtures and are the dev/prod workload; they materialize into the **`analytics`** schema. The `ftable_*` models include deliberately-broken ones (`ftable_e`/`ftable_g` JOIN a non-existent table) that continuo uses to exercise failure paths — they will fail at run time and are useful for demoing the reject path; remove them for a clean production workload.

## Required CI secrets

Configure these in the repo's Actions secrets before the workflow can run:

| Secret | Purpose |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub user; **must match** the username continuo's executor uses to pull job images, and the `FROM carolsimone/dbt-base` in the service Dockerfiles. |
| `DOCKERHUB_TOKEN` | Docker Hub push token. |
| `HETZNER_S3_ACCESS_KEY_ID` / `HETZNER_S3_SECRET_ACCESS_KEY` | Hetzner object-storage credentials (the `continuo-dev` bucket). |
| `HETZNER_HOST` | `continuo-server` host/IP (SSH as root). |
| `HETZNER_SSH_KEY` | Private SSH key authorized on the server (same key continuo's own deploy uses). |

## Status

The pipeline is scaffolded and correct by design but **unvalidated** — it needs the secrets above and a first live run against the dev cluster to shake out (dbt-compile quirks, S3 endpoint TLS, the SSH/port-forward path). The first run performs the one-time bootstrap of `current_prod`.

## Local checks

```bash
uv sync --frozen
uv run pytest tests/           # dbt_upload unit tests
shellcheck scripts/release.sh
```
