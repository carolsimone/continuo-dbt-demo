# Extract `dbt_load` Library + CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the `dbt_upload` tool into a self-contained `dbt-loader/` library (package renamed `dbt_load`, dist `dbt-loader`) with its own packaging, tests, Dockerfile, and CI (host unit job + compose integration job), leaving `base/`/`services/`/`scripts/` in place.

**Architecture:** Pure file-move + rename refactor — no behavior change. The library's unit tests stay pure (no dbt/S3); the one integration test moves to `dbt-loader/integration/` and runs against a docker-compose stack (localstack + postgres + the tool image, which is `FROM dbt-base`). Existing references in `release.yml` and the root `README.md` are updated; a minimal root `pyproject.toml` keeps the leftover `base/`+`scripts/` tests runnable.

**Tech Stack:** Python 3.12, uv, hatchling, pytest, dbt-core/dbt-postgres (in `dbt-base`), boto3/localstack, postgres, Docker Compose, GitHub Actions.

## Global Constraints

- Package import name: `dbt_load`. Distribution name: `dbt-loader`. (Verbatim.)
- dbt pins live only in `base/Dockerfile`: `dbt-core==1.12.0b1`, `dbt-postgres==1.10.0`. Do not duplicate.
- The tool depends on a `dbt` binary at runtime only, never at import time.
- Host runs are macOS (darwin): `sed -i` requires the `''` argument form.
- Leftover root tests (`tests/test_validation_*.py`, `tests/test_seed_validation_runner.py`, `tests/test_validation_result.py`, `tests/test_rebuild_services.py`) must still pass after every task.
- `services/` are example dbt projects shared with the rest of the repo; the integration stack bind-mounts them (read-write — `dbt compile` writes `target/`, which is gitignored).
- Prefer `git mv` for moves to preserve history.
- Exclude `.claude/worktrees/**` from all repo-wide greps (gitignored worktrees).
- Branch: `extract-dbt-loader-library` (already created and checked out).

---

### Task 1: Carve out the `dbt-loader/` library (package + unit tests + packaging)

**Files:**
- Move: `dbt_upload/` → `dbt-loader/dbt_load/`
- Move: `pyproject.toml` → `dbt-loader/pyproject.toml`; `uv.lock` → `dbt-loader/uv.lock`; `targets.yaml` → `dbt-loader/targets.yaml`
- Move: `tests/test_cli.py`, `tests/test_compile.py`, `tests/test_config.py` → `dbt-loader/tests/`
- Move: `tests/test_upload.py` → `dbt-loader/integration/test_upload.py`
- Modify: every moved `.py` (rename `dbt_upload` → `dbt_load`); `dbt-loader/pyproject.toml`
- Create: `dbt-loader/integration/__init__.py` (empty, optional), root `pyproject.toml` (minimal test harness)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: importable package `dbt_load` with modules `dbt_load.cli` (`main`, `cli`, `_find_targets_yaml`), `dbt_load.compile` (`compile_service`, `compile_services`), `dbt_load.config` (`load_target`, `resolve_service_dirs`), `dbt_load.upload` (`next_version`, `upload_manifest`, `upload_services`). Distribution `dbt-loader`. Module entrypoint `python -m dbt_load`.

- [ ] **Step 1: Create the new directory skeleton and move files with `git mv`**

```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
mkdir -p dbt-loader/tests dbt-loader/integration
git mv dbt_upload dbt-loader/dbt_load
git mv pyproject.toml dbt-loader/pyproject.toml
git mv uv.lock dbt-loader/uv.lock
git mv targets.yaml dbt-loader/targets.yaml
git mv tests/test_cli.py dbt-loader/tests/test_cli.py
git mv tests/test_compile.py dbt-loader/tests/test_compile.py
git mv tests/test_config.py dbt-loader/tests/test_config.py
git mv tests/test_upload.py dbt-loader/integration/test_upload.py
```

- [ ] **Step 2: Rename `dbt_upload` → `dbt_load` in all moved Python files**

```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
grep -rl 'dbt_upload' dbt-loader/dbt_load dbt-loader/tests dbt-loader/integration \
  | xargs sed -i '' 's/dbt_upload/dbt_load/g'
```

This rewrites internal imports (`from dbt_load.compile import ...`), `__main__.py`'s `from dbt_load.cli import cli`, the `argparse` `prog="dbt_load"`, all `@patch("dbt_load....")` / `patch("dbt_load.upload.boto3.client")` strings, and docstrings. (The hyphenated `dbt-compile-and-load` string in the integration header is NOT matched here — handled in Task 2.)

- [ ] **Step 3: Verify no `dbt_upload` references remain in the moved code**

Run:
```bash
grep -rn 'dbt_upload' dbt-loader/
```
Expected: no output (exit code 1).

- [ ] **Step 4: Update `dbt-loader/pyproject.toml` distribution name and wheel target**

Change line `name = "dbt-compile-and-load"` to:
```toml
name = "dbt-loader"
```
Change line `only-include = ["dbt_upload"]` to:
```toml
only-include = ["dbt_load"]
```
Leave `version`, `requires-python`, `dependencies` (`boto3`, `pyyaml`), the `dev` extra (`pytest`, `psycopg2-binary`), `[tool.pytest.ini_options] pythonpath = ["."]`, and the `[build-system]` block unchanged.

- [ ] **Step 5: Regenerate the library lockfile for the new dist name**

Run:
```bash
cd /Users/simonecarolini/github/continuo-dbt-demo/dbt-loader && uv lock
```
Expected: `uv.lock` updated; the project entry is now `name = "dbt-loader"`.

- [ ] **Step 6: Create a minimal root test-harness `pyproject.toml` for the leftover tests**

Create `pyproject.toml` (repo root) with exactly:
```toml
# Minimal test harness for the leftover base/ + scripts/ tests that have not yet
# been carved into their own components (Phase C/D). The dbt_load library has its
# own packaging under dbt-loader/. This file is intentionally NOT a distributable
# package — it only provides pythonpath + test deps so `tests/` keeps running.
[project]
name = "continuo-dbt-demo"
version = "0.0.0"
requires-python = ">=3.12"
dependencies = [
    "boto3>=1.34.0",
    "pyyaml>=6.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0.0",
    "psycopg2-binary>=2.9.0",
]

[tool.pytest.ini_options]
pythonpath = ["."]
```

- [ ] **Step 7: Run the library unit tests**

Run:
```bash
cd /Users/simonecarolini/github/continuo-dbt-demo/dbt-loader && uv sync --frozen --extra dev && uv run pytest tests/ -v
```
Expected: PASS — all tests in `test_cli.py`, `test_compile.py`, `test_config.py` green; no dbt/localstack/postgres needed.

- [ ] **Step 8: Run the leftover root tests via the new minimal harness**

Run:
```bash
cd /Users/simonecarolini/github/continuo-dbt-demo && uv run --extra dev pytest tests/ -v
```
Expected: PASS — `test_validation_runner.py`, `test_seed_validation_runner.py`, `test_validation_result.py`, `test_rebuild_services.py` all green. (This generates a root `uv.lock`; that is expected and committed.)

- [ ] **Step 9: Commit**

```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
git add -A
git commit -m "refactor: extract dbt_load library into dbt-loader/ (Phase B)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Integration stack (Dockerfile, compose, localstack init)

**Files:**
- Move: `Dockerfile.upload` → `dbt-loader/Dockerfile`
- Modify: `dbt-loader/Dockerfile`; `dbt-loader/integration/test_upload.py` (header docstring only)
- Create: `dbt-loader/docker-compose.test.yml`, `dbt-loader/scripts/localstack-init.sh`

**Interfaces:**
- Consumes: `dbt_load` package from Task 1; the `dbt-base:latest` image (built from `base/`); example projects at repo-root `services/`.
- Produces: `docker compose -f dbt-loader/docker-compose.test.yml` stack with a `tests` service whose exit code reflects the integration suite. Image built from `dbt-loader/Dockerfile` exposes `dbt` on PATH + the `dbt_load` venv.

- [ ] **Step 1: Move the upload Dockerfile into the library**

```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
git mv Dockerfile.upload dbt-loader/Dockerfile
```

- [ ] **Step 2: Update `dbt-loader/Dockerfile` for the new package name, dev deps, and integration tests**

Replace the file contents with exactly:
```dockerfile
FROM dbt-base:latest

# Clear the inherited dbt-base entrypoint; callers use docker exec / compose
# command with explicit commands.
ENTRYPOINT []

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY pyproject.toml uv.lock ./
# --extra dev so pytest + psycopg2-binary are present for the integration tests.
RUN uv sync --frozen --extra dev

COPY dbt_load/ ./dbt_load/
COPY targets.yaml .
COPY tests/ ./tests/
COPY integration/ ./integration/

CMD ["tail", "-f", "/dev/null"]
```

- [ ] **Step 3: Update the integration test header docstring**

In `dbt-loader/integration/test_upload.py`, replace the module docstring (lines 1-12) with:
```python
"""
Integration tests for the dbt_load compile+upload pipeline.
Requires localstack at S3_ENDPOINT_URL (default: http://localstack:4566) + Postgres.
Run via the docker-compose stack from the dbt-loader/ directory:
  docker compose -f docker-compose.test.yml up --build \
    --abort-on-container-exit --exit-code-from tests
The `services/` example dbt projects are bind-mounted to /app/services by compose.
"""
```
Leave the rest of the file (including `SERVICES_DIR = "/app/services"`) unchanged.

- [ ] **Step 4: Create the localstack bucket-init script**

Create `dbt-loader/scripts/localstack-init.sh` with:
```sh
#!/bin/sh
# Runs inside localstack once it is ready (mounted into /etc/localstack/init/ready.d/).
# The integration tests assume the bucket already exists (they never call create_bucket).
awslocal s3 mb s3://continuo
```
Then make it executable:
```bash
chmod +x /Users/simonecarolini/github/continuo-dbt-demo/dbt-loader/scripts/localstack-init.sh
```

- [ ] **Step 5: Create `dbt-loader/docker-compose.test.yml`**

Create the file with exactly:
```yaml
# Integration test stack for the dbt_load library.
# Build dbt-base first (the tests image is FROM dbt-base):
#   docker build -t dbt-base:latest ../base
# Then:
#   docker compose -f docker-compose.test.yml up --build \
#     --abort-on-container-exit --exit-code-from tests
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: continuo_svc
      POSTGRES_PASSWORD: runner
      POSTGRES_DB: continuo_dbt
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "continuo_svc", "-d", "continuo_dbt"]
      interval: 5s
      timeout: 5s
      retries: 10

  localstack:
    image: localstack/localstack
    environment:
      SERVICES: s3
    volumes:
      - ./scripts/localstack-init.sh:/etc/localstack/init/ready.d/init-bucket.sh
    healthcheck:
      # Passes only once the ready.d hook has created the bucket — avoids the
      # race where tests start before the bucket exists.
      test: ["CMD", "awslocal", "s3", "ls", "s3://continuo"]
      interval: 5s
      timeout: 5s
      retries: 20

  tests:
    build:
      context: .
      dockerfile: Dockerfile
    depends_on:
      postgres:
        condition: service_healthy
      localstack:
        condition: service_healthy
    environment:
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      AWS_DEFAULT_REGION: us-east-1
      S3_ENDPOINT_URL: http://localstack:4566
      S3_BUCKET: continuo
      S3_ENV: local
      DBT_POSTGRES_HOST: postgres
      DBT_POSTGRES_PORT: "5432"
      DBT_POSTGRES_DB: continuo_dbt
      DBT_POSTGRES_USER: continuo_svc
      DBT_POSTGRES_PASSWORD: continuo
    volumes:
      # dbt writes target/ during compile, so this must be writable (target/ is gitignored).
      - ../services:/app/services
    command: ["uv", "run", "pytest", "integration/", "-v"]
```

- [ ] **Step 6: Build dbt-base and run the integration stack**

Run:
```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
docker build -t dbt-base:latest base/
docker compose -f dbt-loader/docker-compose.test.yml up --build --abort-on-container-exit --exit-code-from tests
```
Expected: the `tests` container runs `pytest integration/` and all tests in `test_upload.py` PASS; compose exits 0 (the run's exit code is the `tests` container's).

- [ ] **Step 7: Tear down the stack**

Run:
```bash
docker compose -f /Users/simonecarolini/github/continuo-dbt-demo/dbt-loader/docker-compose.test.yml down -v
```
Expected: containers + volumes removed.

- [ ] **Step 8: Commit**

```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
git add -A
git commit -m "test: docker-compose integration stack for dbt_load

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `dbt-loader/` library (Task 1) + `dbt-loader/docker-compose.test.yml` (Task 2) + `base/` (for `dbt-base:latest`).
- Produces: a `ci.yml` workflow with jobs `dbt-loader-unit` and `dbt-loader-integration`.

- [ ] **Step 1: Create `.github/workflows/ci.yml`**

Create the file with exactly:
```yaml
name: ci

on:
  push:
  pull_request:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  dbt-loader-unit:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    defaults:
      run:
        working-directory: dbt-loader
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - uses: astral-sh/setup-uv@v5
      - name: Unit tests (no external services)
        run: |
          uv sync --frozen --extra dev
          uv run pytest tests/ -v

  dbt-loader-integration:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - name: Build dbt-base (the tests image is FROM dbt-base)
        run: docker build -t dbt-base:latest base/
      - name: Integration tests (docker compose)
        run: |
          docker compose -f dbt-loader/docker-compose.test.yml up --build \
            --abort-on-container-exit --exit-code-from tests
      - name: Tear down
        if: always()
        run: docker compose -f dbt-loader/docker-compose.test.yml down -v
```

- [ ] **Step 2: Validate the workflow YAML**

Run (uses actionlint if available, else a YAML parse):
```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
if command -v actionlint >/dev/null 2>&1; then actionlint .github/workflows/ci.yml; \
else python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('yaml ok')"; fi
```
Expected: `yaml ok` (or no actionlint findings).

- [ ] **Step 3: Commit**

```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
git add .github/workflows/ci.yml
git commit -m "ci: add unit + compose-integration workflow for dbt_load

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Update `release.yml` references

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: the relocated `dbt-loader/` library + `dbt_load` module name.
- Produces: a release workflow whose install/run steps and path filters point at the new locations.

- [ ] **Step 1: Update the path-filter trigger**

In `.github/workflows/release.yml`, in the `on.push.paths` list, change:
```yaml
      - 'dbt_upload/**'
      - 'targets.yaml'
```
to:
```yaml
      - 'dbt-loader/**'
```
(`dbt-loader/**` already covers the moved `targets.yaml`.)

- [ ] **Step 2: Update the install step (name + comments)**

Replace the "Install dbt + dbt_upload" step block:
```yaml
      # dbt is not a dbt_upload dependency (it ships in the dbt-base image); in CI
      # install both into the same interpreter so `python -m dbt_upload` (which
      # shells out to `dbt compile`) finds dbt on PATH.
      - name: Install dbt + dbt_upload
        if: needs.detect.outputs.skip_release != 'true'
        run: |
          pip install --no-cache-dir "dbt-core==1.12.0b1" "dbt-postgres==1.10.0"
          pip install --no-cache-dir -e .
```
with:
```yaml
      # dbt is not a dbt_load dependency (it ships in the dbt-base image); in CI
      # install both into the same interpreter so `python -m dbt_load` (which
      # shells out to `dbt compile`) finds dbt on PATH.
      - name: Install dbt + dbt_load
        if: needs.detect.outputs.skip_release != 'true'
        run: |
          pip install --no-cache-dir "dbt-core==1.12.0b1" "dbt-postgres==1.10.0"
          pip install --no-cache-dir -e ./dbt-loader
```

- [ ] **Step 3: Update the compile+upload invocation**

In the "Compile + upload manifest" step's `run:` block, change:
```yaml
          python -m dbt_upload load \
```
to:
```yaml
          python -m dbt_load load \
```
(The `services/${{ ... }}` path and `--target hetzner` are unchanged — `targets.yaml` is found via the installed package's parent dir, i.e. `dbt-loader/targets.yaml`.)

- [ ] **Step 4: Verify no stale references remain in `release.yml`**

Run:
```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
grep -n 'dbt_upload' .github/workflows/release.yml || echo "clean"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('yaml ok')"
```
Expected: `clean` then `yaml ok`.

- [ ] **Step 5: Commit**

```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
git add .github/workflows/release.yml
git commit -m "ci: point release workflow at relocated dbt_load library

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Update root README + repo-wide sweep

**Files:**
- Modify: `README.md` (repo root)

**Interfaces:**
- Consumes: all prior tasks (final state).
- Produces: documentation consistent with the new layout; a clean repo-wide grep.

- [ ] **Step 1: Update the repo-layout block**

In `README.md`, replace these lines:
```
dbt_upload/      # compile + filter + upload-manifest-to-S3 CLI (compile / upload / load subcommands)
targets.yaml     # S3 targets (localstack for local; hetzner → continuo-dev bucket)
Dockerfile.upload, pyproject.toml, uv.lock, tests/   # dbt_upload packaging + its tests
scripts/release.sh
.github/workflows/release.yml
```
with:
```
dbt-loader/      # the dbt_load library: compile + filter + upload-manifest-to-S3 CLI
                 #   (compile / upload / load); its own pyproject/uv.lock + targets.yaml,
                 #   tests/ (unit), integration/ (real dbt+S3), Dockerfile, docker-compose.test.yml
scripts/release.sh
.github/workflows/   # release.yml (deploy) + ci.yml (tests)
```

- [ ] **Step 2: Update the `dbt_upload` mention in step 2 of "What it does"**

In `README.md`, change `(via \`dbt_upload\`, \`hetzner\` target in \`targets.yaml\`)` to `(via \`dbt_load\`, \`hetzner\` target in \`targets.yaml\`)`.

- [ ] **Step 3: Update the "Local checks" section**

Replace:
```bash
uv sync --frozen
uv run pytest tests/           # dbt_upload unit + integration tests
shellcheck scripts/release.sh
```
with:
```bash
# Library (dbt_load) unit tests — no external services:
cd dbt-loader && uv sync --frozen --extra dev && uv run pytest tests/

# Library integration tests (real dbt compile + S3) via docker compose:
docker build -t dbt-base:latest base/
docker compose -f dbt-loader/docker-compose.test.yml up --build --abort-on-container-exit --exit-code-from tests

# Leftover base/ + scripts/ tests (from repo root):
uv run --extra dev pytest tests/

shellcheck scripts/release.sh
```

- [ ] **Step 4: Update the integration-tests paragraph**

Replace the paragraph beginning "The integration tests in `tests/test_upload.py`..." with:
```
The integration tests in `dbt-loader/integration/test_upload.py` exercise real `dbt compile` and S3 uploads and run via the compose stack above (localstack + Postgres + the `dbt-base`-derived tool image). The CLI, config, compile-wrapper, and per-release upload-layout tests in `dbt-loader/tests/` run without any external services. The leftover `tests/` at the repo root cover the `dbt-base` validation runner and the rebuild script.
```

- [ ] **Step 5: Repo-wide sweep for stale references**

Run:
```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
grep -rn 'dbt_upload\|dbt-compile-and-load\|Dockerfile.upload' \
  --include='*.py' --include='*.yml' --include='*.yaml' --include='*.toml' \
  --include='*.md' --include='Dockerfile*' --include='*.sh' . \
  | grep -v '.claude/worktrees' || echo "clean"
```
Expected: `clean`.

- [ ] **Step 6: Final full verification — both test suites green**

Run:
```bash
cd /Users/simonecarolini/github/continuo-dbt-demo/dbt-loader && uv run pytest tests/ -v
cd /Users/simonecarolini/github/continuo-dbt-demo && uv run --extra dev pytest tests/ -v
```
Expected: both PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/simonecarolini/github/continuo-dbt-demo
git add README.md
git commit -m "docs: update README for dbt-loader layout + CI

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Target layout (dbt-loader/dbt_load, tests/, integration/, pyproject, uv.lock, targets.yaml, Dockerfile, docker-compose.test.yml, scripts/localstack-init.sh, README) → Tasks 1-2, 5. ✓
- Move table → Task 1 Step 1 + Task 2 Step 1. ✓
- Rename `dbt_upload`→`dbt_load` (imports, mocks, prog, docstrings) → Task 1 Step 2. ✓
- pyproject name + wheel + relock → Task 1 Steps 4-5. ✓
- targets.yaml parent-dir resolution (no code change) → covered (no step needed; verified by Task 1 Step 7 and Task 2 Step 6 which exercise `--target`/load paths via tests). ✓
- Dockerfile changes → Task 2 Step 2. ✓
- release.yml reference edits → Task 4. ✓
- README reference edits → Task 5. ✓
- CI (unit + integration jobs, triggers, concurrency, compose, exit-code-from, teardown) → Task 3. ✓
- docker-compose.test.yml (postgres, localstack+init, tests, env, mount) → Task 2 Steps 4-5. ✓
- Known coupling (services bind-mount) → Task 2 Step 5 (corrected to read-write). ✓
- Verification commands → Tasks 1,2,5 + final sweep. ✓
- **Addition beyond spec:** minimal root `pyproject.toml` to keep leftover tests runnable (spec required "root tests still pass" but didn't say how) → Task 1 Step 6. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/vague steps; every code/edit step shows exact content. ✓

**Type/name consistency:** `dbt_load` package + module functions used consistently; compose service named `tests` and `--exit-code-from tests` match across Tasks 2 and 3; `dbt-base:latest` image tag consistent across Tasks 2 and 3. ✓
