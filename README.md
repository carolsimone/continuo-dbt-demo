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

   **Base-change fan-out.** When a push changes `base/**` (the shared `dbt-base` — e.g. `validation_runner.py` or a shared macro), the one-changed-service rule isn't enough: every *other* service still runs from an image built on the **old** base, and since a changed-node validation spans the full cross-service closure (service-2/service-3 form a cycle), those stale-base images make releases reject at `validating` with no way to self-heal. So on any `base/**` change the workflow runs `scripts/rebuild_services_from_base.sh`, which re-bakes **every** service image FROM the fresh base and re-pushes it under the tag continuo's prod pointers already reference — the short SHA of the last commit that touched each `services/<svc>/`. No `service_prod` pointer moves; combined with the validation Job's `imagePullPolicy: Always`, every validation and run then re-pulls the fresh base. A base-only push (no service changed) runs just this fan-out and posts no release.
2. **Compiles** the changed service (`dbt compile` against an ephemeral Postgres — no data needed, compile only resolves refs/jinja into `manifest.json`) and **uploads** its manifest to the Hetzner object store at the canonical key `<service>/<release_id>/manifest.json` (via `dbt_upload`, `hetzner` target in `targets.yaml`). The manifest is filtered before upload: only `model` and `seed` nodes are kept, and any node tagged `local_stub` is dropped. The image tag is **not** stored in S3.
3. **Drives the release** (`scripts/release.sh`): SSHes to `continuo-server`, port-forwards the internal `release-controller` ClusterIP (`:8088`), reads `GET /current-prod`, then `POST /releases` and **polls to a terminal status — failing the deploy on `rejected`**.

### The release contract (what `scripts/release.sh` sends)

continuo models a release as a **single changed service**. The request body is:

```json
{"release_id": "rel-<sha>-<run>", "service": "service-3", "image_tag": "<sha>", "bootstrap": false}
```

- `service` and `image_tag` are **single values**, not maps. There is **no `manifests_uri`** in the body — the controller derives the S3 key itself from `bucket + service + release_id` (continuo's `CanonicalManifestKey`). There is **no `service_metadata.json` sidecar**; the image tag travels in this body, not in S3.
- The controller replies `202 Accepted` with `{"release_id": "...", "status": "received"}`.
- The script then polls `GET /releases/<release_id>` until `status` is terminal: `promoted` (success) or `rejected` (failure). The other services' manifests are already in S3 from their own releases; the controller reconstructs the full set via the live `service_prod` pointers.

### Connection model

continuo's release API has no public domain yet — it is an internal `ClusterIP` on `:8088`. The only way in is SSH onto the Hetzner node and a server-side `kubectl port-forward`. Each API call (`/current-prod`, `POST /releases`, each poll) runs in its **own** short-lived SSH session that opens a one-shot port-forward, issues exactly one `curl`, and tears it down — a single long-held tunnel would be reaped by NAT/firewall/sshd idle timeouts during the minutes-long poll.

### First run = bootstrap

`release.sh` sets `bootstrap:true` automatically when `GET /current-prod` reports no current release (`current_prod_release_id` empty). A bootstrap release **promotes without validation** — necessary because, against an empty `current_prod`, normal validation rejects every cross-service upstream as new. Every subsequent run posts `bootstrap:false` and goes through validation. (Bootstrap promotes whatever topology it carries, so the first push must be a trusted one.)

## Repo layout

```
base/            # dbt-base image: pinned dbt-core/dbt-postgres + shared macros (generate_schema_name)
services/        # one directory per dbt service: dbt_project.yml, profiles.yml (schema: analytics),
                 #   models/, seeds/, Dockerfile (FROM <user>/dbt-base:latest)
dbt_upload/      # compile + filter + upload-manifest-to-S3 CLI (compile / upload / load subcommands)
targets.yaml     # S3 targets (localstack for local; hetzner → continuo-dev bucket)
Dockerfile.upload, pyproject.toml, uv.lock, tests/   # dbt_upload packaging + its tests
scripts/release.sh
.github/workflows/release.yml
```

The services fall into two groups. `core`, `finance`, and `marketing` are clean example workloads. `service-1`, `service-2`, and `service-3` are copied from continuo's e2e fixtures and include deliberately-broken models (the `ftable_*` models in service-2/3 JOIN a non-existent table) that continuo uses to exercise failure paths — they fail at run time and are useful for demoing the reject path. All services materialize into the **`analytics`** schema (set in each `profiles.yml`).

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
uv sync --frozen
uv run pytest tests/           # dbt_upload unit + integration tests
shellcheck scripts/release.sh
```

The integration tests in `tests/test_upload.py` exercise real `dbt compile` and S3 uploads and expect localstack reachable at `S3_ENDPOINT_URL` (default `http://localstack:4566`) plus a Postgres for compile; see the header of that file for the full `docker exec` invocation. The CLI, config, compile-wrapper, and per-release upload-layout tests run without any external services.
