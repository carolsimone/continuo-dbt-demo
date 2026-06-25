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
