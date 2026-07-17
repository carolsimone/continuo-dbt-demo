#!/usr/bin/env bash
# Local functional smoke for the marketing cost-allocation models. Builds the
# marketing image, stands up an ephemeral postgres, runs `dbt build` (seeds +
# models + tests), then asserts the row shapes the models are supposed to have.
# Exits non-zero on the first failure. Gate every marketing push on it.
#
# marketing reads only its own seeds, so unlike the finance smoke there is no
# cross-service upstream to stub.
set -euo pipefail

IMG=marketing-models-smoke
PG=marketing-smoke-pg
NET=marketing-smoke-net
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

cleanup() {
  docker rm -f "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

echo "== build marketing image (real Dockerfile) =="
docker build -t "$IMG" -f "$ROOT/services/marketing/Dockerfile" "$ROOT/services/marketing"

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

echo "== create analytics schema =="
docker exec -i "$PG" psql -U continuo_svc -d continuo_dbt <<'SQL'
CREATE SCHEMA IF NOT EXISTS analytics;
SQL

echo "== dbt build (seeds + models + tests) =="
# The image ENTRYPOINT is a local-debug script that ignores its args and always
# runs a hardcoded `dbt run`. Override it so we actually get `dbt build`.
docker run --rm --network "$NET" \
  -e DBT_POSTGRES_HOST="$PG" -e DBT_POSTGRES_PORT=5432 \
  -e DBT_POSTGRES_DB=continuo_dbt -e DBT_POSTGRES_USER=continuo_svc -e DBT_POSTGRES_PASSWORD=runner \
  --entrypoint dbt "$IMG" build --profiles-dir /project

# assert_scalar <label> <expected> <sql>
assert_scalar() {
  local label="$1" expected="$2" sql="$3" actual
  actual="$(docker exec "$PG" psql -U continuo_svc -d continuo_dbt -tAc "$sql" | tr -d '[:space:]')"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: ${label}: expected ${expected}, got ${actual}"
    return 1
  fi
  echo "OK: ${label} = ${actual}"
}

echo "== assert marketing_spend_monthly shape =="
assert_scalar "spend_monthly row count (5 channels x 36 months)" 180 \
  "SELECT COUNT(*) FROM analytics.marketing_spend_monthly"
assert_scalar "spend_monthly distinct channels" 5 \
  "SELECT COUNT(DISTINCT channel) FROM analytics.marketing_spend_monthly"
assert_scalar "spend_monthly distinct months" 36 \
  "SELECT COUNT(DISTINCT spend_month) FROM analytics.marketing_spend_monthly"
assert_scalar "spend_monthly months are all first-of-month" 0 \
  "SELECT COUNT(*) FROM analytics.marketing_spend_monthly WHERE EXTRACT(DAY FROM spend_month) <> 1"
assert_scalar "spend_monthly campaign_count total equals seed rows" 396 \
  "SELECT SUM(campaign_count) FROM analytics.marketing_spend_monthly"
assert_scalar "spend_monthly total equals seed total" t \
  "SELECT ROUND(SUM(spend_eur),2) = (SELECT ROUND(SUM(amount::numeric),2) FROM analytics.seed_marketing_spend) FROM analytics.marketing_spend_monthly"

echo "SMOKE OK"
