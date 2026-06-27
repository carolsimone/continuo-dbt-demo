FROM python:3.12-slim

# dbt is not a dbt_load dependency — the integration tests shell out to
# `dbt compile` against the mounted services, so dbt must be on PATH. Install it
# system-wide (the same pins the services use); the project's own deps come from
# uv below. No boto3/validator: dbt-loader only compiles + uploads manifests.
RUN pip install --no-cache-dir "dbt-core==1.12.0b1" "dbt-postgres==1.10.0" uv

WORKDIR /app

COPY pyproject.toml uv.lock ./
# Install dependencies only (cached layer) before the source is present.
# --no-install-project: the project itself is installed after its source is
# copied — required because the wheel force-includes targets.yaml, which
# hatchling reads when building the project. --extra dev pulls in pytest +
# psycopg2-binary for the integration tests.
RUN uv sync --frozen --no-install-project --extra dev

COPY dbt_load/ ./dbt_load/
COPY targets.yaml .
COPY tests/ ./tests/
COPY integration/ ./integration/

# Now install the project itself against the copied source.
RUN uv sync --frozen --extra dev

CMD ["tail", "-f", "/dev/null"]
