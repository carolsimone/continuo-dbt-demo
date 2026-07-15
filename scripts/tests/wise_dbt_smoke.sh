#!/usr/bin/env bash
# Local functional smoke for the finance wise-dbt CLI. Builds the finance image,
# stands up an ephemeral postgres with a minimal analytics schema + a stub of the
# cross-service upstream (analytics.seed_fx_transactions), then exercises every
# verb the deployed dialect routes through wise-dbt: compile-project, load-seed,
# run-model, build-model, test-model. Exits non-zero on the first failure. Gate
# every finance push on it.
set -euo pipefail

IMG=finance-wisedbt-smoke
PG=wise-smoke-pg
NET=wise-smoke-net
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

cleanup() {
  docker rm -f "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

echo "== build finance image (real Dockerfile) =="
docker build -t "$IMG" -f "$ROOT/services/finance/Dockerfile" "$ROOT/services/finance"

echo "== start ephemeral postgres =="
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_USER=continuo_svc -e POSTGRES_PASSWORD=runner -e POSTGRES_DB=continuo_dbt \
  postgres:16-alpine >/dev/null

echo "== wait for postgres =="
for _ in $(seq 1 30); do
  if docker exec "$PG" pg_isready -U continuo_svc -d continuo_dbt >/dev/null 2>&1; then break; fi
  sleep 1
done

echo "== create analytics schema + cross-service upstream stub =="
docker exec -i "$PG" psql -U continuo_svc -d continuo_dbt <<'SQL'
CREATE SCHEMA IF NOT EXISTS analytics;
DROP TABLE IF EXISTS analytics.seed_fx_transactions;
CREATE TABLE analytics.seed_fx_transactions (
  transaction_id text, user_id text, amount numeric,
  currency_from text, currency_to text, rate numeric, created_at date
);
-- created_at must land on a (currency, rate_date) pair that actually exists in
-- seeds/seed_fx_rates_eur.csv, otherwise the model's LEFT JOIN yields a NULL
-- rate_to_eur/amount_eur and fails the not_null tests exercised by build-model
-- and test-model.
INSERT INTO analytics.seed_fx_transactions VALUES
  ('t1','u1',100,'USD','EUR',0.9,'2024-01-14');
SQL

run_verb() { # <expect-banner-substr> <verb...>
  local expect="$1"; shift
  local out
  # The image's own ENTRYPOINT (/entrypoint.sh) is a local-debug-only script
  # that ignores its positional args and always shells out to a hardcoded
  # `dbt run`. Override it so the container actually execs wise-dbt with the
  # verb we're testing, instead of silently running entrypoint.sh's own logic.
  out="$(docker run --rm --network "$NET" \
    -e DBT_POSTGRES_HOST="$PG" -e DBT_POSTGRES_PORT=5432 \
    -e DBT_POSTGRES_DB=continuo_dbt -e DBT_POSTGRES_USER=continuo_svc -e DBT_POSTGRES_PASSWORD=runner \
    --entrypoint wise-dbt "$IMG" "$@" 2>&1)"
  echo "$out"
  echo "$out" | grep -q "WISE-DBT WRAPPER v1" || { echo "FAIL: banner missing for '$*'"; return 1; }
  echo "$out" | grep -q "$expect" || { echo "FAIL: expected '$expect' in output for '$*'"; return 1; }
}

echo "== compile-project =="
run_verb "Running with dbt=" compile-project

echo "== load-seed (finance own seed) =="
run_verb "Running with dbt=" load-seed seed_fx_rates_eur

echo "== run-model (needs upstream stub + seed) =="
run_verb "Running with dbt=" run-model fx_transactions_eur

echo "== build-model = dbt build (materialize + test) =="
run_verb "Running with dbt=" build-model fx_transactions_eur

echo "== test-model (tests the built model) =="
run_verb "Running with dbt=" test-model fx_transactions_eur

echo "SMOKE OK"
