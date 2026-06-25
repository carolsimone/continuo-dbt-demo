# Extract `dbt_load` into a self-contained library (Phase B) + CI

**Date:** 2026-06-25
**Status:** Approved (design); implementation plan pending
**Branch:** `extract-dbt-loader-library`

## Problem

The repo conflates three unrelated concerns under one Python root:

- **`dbt_upload/`** — a portable tool that compiles a dbt project's artifacts and
  loads the manifests to S3 at a known layout. It depends on a `dbt` binary only
  at *runtime* (a `subprocess` call), never at import time.
- **`base/`** — the `dbt-base` runtime image: dbt-core/dbt-postgres + the
  `validation_runner` and shared macros.
- **`services/`** — example dbt projects (just dbt; organized however a domain wants).

They share a single root `pyproject.toml` and a single `tests/` directory that
together own Python from all three, plus `targets.yaml` and `Dockerfile.upload`
at the root. That shared root is the "ball of mud". There is also no CI: the
test suite is only runnable by hand.

## Goal (this phase only)

Phase B of a larger untangling. Extract **only** the tool into a clean,
self-contained library directory — renamed to package **`dbt_load`** /
distribution **`dbt-loader`** — with its own packaging, its own tests, its own
Dockerfile, and its own CI (unit job + compose-based integration job). Leave
`base/`, `services/`, and `scripts/` exactly where they are for a later phase.

Keep everything in **one repo** for now. The success criterion is that the
boundary is clean enough that lifting `dbt-loader/` into its own repo later is a
`git mv` + push, not surgery.

### Non-goals
- No separate repos.
- No touching `base/`, `services/`, or `scripts/` layout (beyond references that
  break — see below).
- No behavior change to the tool itself; tests must pass unchanged in substance
  (only import paths / package name update).

## Target layout

```
dbt-loader/                  ← self-contained library (dist: dbt-loader)
  dbt_load/                  ← the package (was dbt_upload/)
    __init__.py __main__.py cli.py compile.py config.py upload.py
  tests/                     ← pure unit tests (no dbt, no services, no S3)
    test_cli.py test_compile.py test_config.py
  integration/               ← the one place the tool meets real dbt + S3
    test_upload.py
  pyproject.toml             ← own packaging (name = "dbt-loader")
  uv.lock
  targets.yaml               ← tool config (parent-of-package resolution)
  Dockerfile                 ← was Dockerfile.upload (FROM dbt-base)
  docker-compose.test.yml    ← integration stack: tool image + localstack + postgres
  scripts/localstack-init.sh ← creates the `continuo` bucket on localstack ready
  README.md                  ← how to test the library locally

(unchanged this phase: base/, services/, scripts/, .github/workflows/release.yml*)
* release.yml gets reference-only edits, no structural change
```

## What moves and what changes

### Moves (prefer `git mv` to preserve history)
| From (repo root) | To |
|---|---|
| `dbt_upload/` | `dbt-loader/dbt_load/` |
| `pyproject.toml` | `dbt-loader/pyproject.toml` |
| `uv.lock` | `dbt-loader/uv.lock` |
| `targets.yaml` | `dbt-loader/targets.yaml` |
| `Dockerfile.upload` | `dbt-loader/Dockerfile` |
| `tests/test_cli.py`, `tests/test_compile.py`, `tests/test_config.py` | `dbt-loader/tests/` |
| `tests/test_upload.py` | `dbt-loader/integration/test_upload.py` |

The remaining root `tests/` files (`test_validation_*`, `test_seed_*`,
`test_validation_result`, `test_rebuild_services`) **stay** — they belong to
`base/` and `scripts/` and are out of scope for Phase B.

### Rename: `dbt_upload` → `dbt_load`
Update every import and mock target (verified set):
- Package-internal imports: `cli.py` imports `dbt_upload.{compile,config,upload}`;
  `__main__.py` imports `dbt_upload.cli`.
- `argparse` `prog="dbt_upload"` → `prog="dbt_load"`; module docstrings.
- Tests: `from dbt_upload...` and all `@patch("dbt_upload....")` /
  `patch("dbt_upload.upload.boto3.client")` strings → `dbt_load...`.

### `pyproject.toml`
- `name = "dbt-compile-and-load"` → `name = "dbt-loader"`.
- `[tool.hatch.build.targets.wheel] only-include = ["dbt_upload"]` → `["dbt_load"]`.
- Keep `version`, `requires-python`, `dependencies` (boto3, pyyaml), `dev`
  extras (pytest, psycopg2-binary), and `pythonpath = ["."]` (now resolves to
  `dbt-loader/`, so `import dbt_load` works under pytest).
- Regenerate `uv.lock` for the new dist name (`uv lock`).

### `targets.yaml` resolution (no code change needed)
`_find_targets_yaml()` already looks at the package's parent dir. After the move
the package lives at `dbt-loader/dbt_load/`, parent `dbt-loader/`, so
`dbt-loader/targets.yaml` is found in dev; and in the image (`/app/dbt_load/` →
`/app/targets.yaml`) the existing comment still holds. The CWD fallback is kept.
The warning comment added earlier is preserved.

### `Dockerfile` (was `Dockerfile.upload`)
- Build context becomes `dbt-loader/`.
- `COPY dbt_upload/ ./dbt_upload/` → `COPY dbt_load/ ./dbt_load/`.
- `COPY tests/ ./tests/` → copy both `tests/` and `integration/`.
- `COPY targets.yaml .`, `pyproject.toml`, `uv.lock` unchanged in intent.
- `services/` is **not** in this build context (stays at repo root); the
  integration test gets them via a compose bind-mount (below).
- Dev deps for running pytest in the image: `uv sync --frozen --extra dev`
  (the integration test needs pytest + psycopg2-binary present).

### `release.yml` (reference-only edits)
- Path filters: `- 'dbt_upload/**'` → `- 'dbt-loader/**'`, and `- 'targets.yaml'`
  → `- 'dbt-loader/targets.yaml'` (it moved under the library). `dbt-loader/**`
  already covers it, but keep the explicit line for clarity/parity with the rest.
- `pip install --no-cache-dir -e .` → `-e ./dbt-loader`.
- `python -m dbt_upload load "services/${svc}" --target hetzner ...` →
  `python -m dbt_load load ...` (run from repo root; `services/` path and
  `--target hetzner` still resolve — targets.yaml found via the installed
  package's parent dir).
- Update the two explanatory comments mentioning `dbt_upload`.

### `README.md` (repo root) — reference edits
- Repo-layout block: replace the `dbt_upload/ … targets.yaml … Dockerfile.upload,
  pyproject.toml, uv.lock, tests/` lines with the new `dbt-loader/` component.
- "Local checks" section: the tool's tests now run under `dbt-loader/`
  (`cd dbt-loader && uv run pytest tests/`); integration via
  `docker compose -f dbt-loader/docker-compose.test.yml up --build`.
- Update the `dbt_upload` mention in step 2 to `dbt_load`.

## CI design (Phase B scope: the library only)

New workflow `.github/workflows/ci.yml` (workflows must live at repo root).
Triggers: `pull_request` + `push`; `concurrency` cancels superseded runs on the
same ref. Two jobs:

1. **`dbt-loader-unit`** (host, fast, no services):
   - `actions/setup-python@v5` (3.12), install `uv`.
   - `working-directory: dbt-loader`: `uv sync --frozen --extra dev` then
     `uv run pytest tests/`.
   - Proves the tool is portable: zero dbt, zero localstack, zero postgres.

2. **`dbt-loader-integration`** (docker compose):
   - `docker build -t dbt-base:latest base/` (the tool image is `FROM dbt-base`;
     compose can't reliably order an image build before a dependent build, so we
     build it explicitly — this also mirrors how the real service images build).
   - `docker compose -f dbt-loader/docker-compose.test.yml up --build
     --abort-on-container-exit --exit-code-from tests` — the tests container's
     exit code becomes the job's; postgres/localstack torn down on completion.
   - `docker compose ... down -v` in `if: always()`.

(Optional path filters limiting CI to `dbt-loader/**` + `base/**` can be added;
default to running on every push/PR for now.)

### `docker-compose.test.yml` (in `dbt-loader/`)
Three services:
- **`postgres`** (`postgres:16`): `POSTGRES_USER=continuo_svc`,
  `POSTGRES_PASSWORD=runner`, `POSTGRES_DB=continuo_dbt`; healthcheck
  `pg_isready`.
- **`localstack`** (`localstack/localstack`, `SERVICES=s3`): mount
  `./scripts/localstack-init.sh` into `/etc/localstack/init/ready.d/` to run
  `awslocal s3 mb s3://continuo` (the tests assume the bucket exists — they never
  call `create_bucket`).
- **`tests`** (build `dbt-loader/Dockerfile`): `depends_on` both healthy; bind-mount
  the repo's example projects `../services:/app/services:ro` (test hardcodes
  `/app/services`); env wired to service names per the `test_upload.py` header
  (`S3_ENDPOINT_URL=http://localstack:4566`, `S3_BUCKET=continuo`, `S3_ENV=local`,
  `AWS_*=test`, `AWS_DEFAULT_REGION=us-east-1`, `DBT_POSTGRES_HOST=postgres`,
  `DBT_POSTGRES_PORT=5432`, `DBT_POSTGRES_DB=continuo_dbt`,
  `DBT_POSTGRES_USER=continuo_svc`, `DBT_POSTGRES_PASSWORD=continuo`);
  command `uv run pytest integration/ -v`.

> Known coupling (acceptable in Phase B): the integration test needs the example
> dbt projects, which still live at repo-root `services/`, so they're bind-mounted
> in. When `dbt-loader/` is eventually extracted to its own repo, it will need a
> small bundled example dbt project instead. Noted for the later phase.

## Verification

- `cd dbt-loader && uv sync --frozen --extra dev && uv run pytest tests/` → green.
- `docker build -t dbt-base:latest base/` then
  `docker compose -f dbt-loader/docker-compose.test.yml up --build
  --abort-on-container-exit --exit-code-from tests` → green.
- `grep -rn dbt_upload` over tracked files (excluding `.claude/worktrees`) → no hits.
- `release.yml` paths/commands reference `dbt-loader` / `dbt_load`.
- Root `tests/` still contains only the `base/`+`scripts/` tests and they still pass.

## Out of scope / later phases
- Phase C: carve `base/` (dbt-base runtime) into its own component + tests.
- Phase D: `scripts/` tooling + its test.
- Possible eventual extraction of `dbt-loader/` to its own repo.
