FROM dbt-base:latest

# Clear the inherited dbt-base entrypoint; callers use docker exec / compose
# command with explicit commands.
ENTRYPOINT []

WORKDIR /app

RUN pip install --no-cache-dir uv

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
