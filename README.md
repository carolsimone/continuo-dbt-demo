# continuo-dbt-demo

A reference **dbt producer** for [continuo](https://github.com/carolsimone/continuo)'s blue/green release pipeline. It owns several dbt services, builds their images, and drives a continuo release from CD — the worked example of how any consumer's CD integrates with continuo.

## Reference implementation of the public "loading releases" interface

This repo is the **reference external integration** for continuo's public release-loading contract. It is a deliberate, independent reimplementation of that contract: it shares **no code** with continuo internals — no Go packages, no shared client library. Everything here (the manifest filtering, the canonical S3 key, the `POST /releases` body, the bootstrap detection) is rebuilt from the contract alone. That duplication is the point: it proves the contract is self-describing enough for an outside team to integrate against without reading continuo's source.

The authoritative contract is documented in continuo:
**[docs/integration/loading-releases.md](https://github.com/carolsimone/continuo/blob/main/docs/integration/loading-releases.md)**.

If this README and that document ever disagree, the continuo doc is authoritative — open an issue against continuo or this repo.

## What it does

On every push to `services/**` (or manual dispatch), `.github/workflows/release.yml`:

1. **Builds + pushes** the one changed service's image to Docker Hub as `<DOCKERHUB_USERNAME>/<service>:<short-sha>` (+ `:latest`). The name/tag is the contract: continuo's executor launches dbt jobs as `<DOCKERHUB_USERNAME>/<service_name>:<image_tag>`. Each service image is **self-contained** (plain dbt + its own project, incl. the `generate_schema_name` macro) — there is no shared base image, so a single-service change rebuilds only that service. Validation runs in a continuo-owned image, so team images carry no validator.
2. **Drives the release** (`scripts/release.sh`): SSHes to `continuo-server`, port-forwards the internal `release-controller` ClusterIP (`:8088`), reads `GET /current-prod`, then `POST /releases` and **polls to a terminal status — failing the deploy on `rejected`**. continuo compiles the changed service and validates the full topology before promoting.

### The release contract (what `scripts/release.sh` sends)

continuo models a release as a **single changed service**. The request body is:

```json
{"release_id": "rel-<sha>-<run>", "service": "service-3", "image_tag": "<sha>", "bootstrap": false, "repo": "<owner>/<repo>", "commit_sha": "<full-sha>"}
```

- `service` and `image_tag` are **single values**, not maps. `repo` and `commit_sha` identify the source push (`github.repository` / `github.sha`). There is **no `service_metadata.json` sidecar**; the image tag travels in this body, not in S3.
- The controller replies `202 Accepted` with `{"release_id": "...", "status": "received"}`.
- The script then polls `GET /releases/<release_id>` until `status` is terminal: `promoted` (success) or `rejected` (failure). The other services' manifests are already in S3 from their own releases; the controller reconstructs the full set via the live `service_prod` pointers.

### Connection model

continuo's release API has no public domain yet — it is an internal `ClusterIP` on `:8088`. The only way in is SSH onto the Hetzner node and a server-side `kubectl port-forward`. Each API call (`/current-prod`, `POST /releases`, each poll) runs in its **own** short-lived SSH session that opens a one-shot port-forward, issues exactly one `curl`, and tears it down — a single long-held tunnel would be reaped by NAT/firewall/sshd idle timeouts during the minutes-long poll.

### First run = bootstrap

`release.sh` sets `bootstrap:true` automatically when `GET /current-prod` reports no current release (`current_prod_release_id` empty). A bootstrap release **promotes without validation** — necessary because, against an empty `current_prod`, normal validation rejects every cross-service upstream as new. Every subsequent run posts `bootstrap:false` and goes through validation. (Bootstrap promotes whatever topology it carries, so the first push must be a trusted one.)

## Repo layout

```
services/        # one directory per dbt service: dbt_project.yml, profiles.yml (schema: analytics),
                 #   macros/ (generate_schema_name), models/, seeds/, Dockerfile (FROM python:3.12-slim, plain dbt + project)
scripts/         # repo CD/utility tooling: release.sh, gen_fx_rates_eur.py
.github/workflows/   # release.yml (deploy)
```

The services fall into two groups. `core`, `finance`, and `marketing` are clean example workloads — the part to read if you're modelling how your own producer integrates. `service-1`, `service-2`, and `service-3` are copied from continuo's e2e fixtures: they carry deliberate cross-service dependencies (including a service-2 ↔ service-3 cycle) and probe / failure nodes whose only purpose is to exercise continuo's validation and reject paths. They are testing scaffolding, not a modelling example. All services materialize into the **`analytics`** schema (set in each `profiles.yml`).

### Cross-service references (important)

A continuo producer's services are **separate dbt projects**, and dbt's `{{ ref() }}` only resolves nodes *within one project*. So a model that depends on a table built by **another** service cannot `ref()` it — that fails at `dbt compile` with `depends on a node named '…' which was not found`. The convention:

- **Within a service** (depends on a seed/model in the same project): use `{{ ref('name') }}`. dbt resolves it and orders the build.
- **Across services** (depends on a table another service produces in the shared `analytics` schema): reference it by its **raw schema-qualified name** — `FROM analytics.table_a` — never `ref()`. continuo sequences the cross-service build itself (via the validation closure and `service_prod` pointers); dbt never needs the upstream in its own graph.

This is the easiest integration mistake to make — even an automated fixer once "corrected" a cross-service `FROM analytics.table_a` into `{{ ref('table_a') }}` and broke the build.

## Required CI secrets

Configure these in the repo's Actions secrets before the workflow can run:

| Secret | Purpose |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub user; **must match** the username continuo's executor uses to pull job images. |
| `DOCKERHUB_TOKEN` | Docker Hub push token. |
| `HETZNER_HOST` | `continuo-server` host/IP (SSH as root). |
| `HETZNER_SSH_KEY` | Private SSH key authorized on the server (same key continuo's own deploy uses). |

## Local checks

```bash
shellcheck scripts/release.sh
```
