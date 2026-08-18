#!/usr/bin/env bash
# Local functional smoke for the finance operational-cost models. Builds the
# finance image, stands up an ephemeral postgres, stubs the cross-service
# upstreams (analytics.seed_fx_transactions with one synthetic row;
# analytics.seed_users from the real core CSV), runs `dbt build` (seeds +
# models + tests), then asserts the row shapes the models are supposed to
# have. Exits non-zero on the first failure. Gate every finance push on it.
set -euo pipefail

IMG=finance-models-smoke
PG=finance-smoke-pg
NET=finance-smoke-net
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

echo "== create analytics schema + cross-service upstream stubs =="
docker exec -i "$PG" psql -U continuo_svc -d continuo_dbt <<'SQL'
CREATE SCHEMA IF NOT EXISTS analytics;
DROP TABLE IF EXISTS analytics.seed_fx_transactions;
CREATE TABLE analytics.seed_fx_transactions (
  transaction_id text, user_id text, amount numeric,
  currency_from text, currency_to text, rate numeric, created_at date
);
-- created_at must land on a (currency, rate_date) pair that actually exists in
-- seeds/seed_fx_rates_eur.csv, otherwise fx_transactions_eur's LEFT JOIN
-- yields NULL rate_to_eur/amount_eur and its not_null tests fail the build.
INSERT INTO analytics.seed_fx_transactions VALUES
  ('t1','u1',100,'USD','EUR',0.9,'2024-01-14');
DROP TABLE IF EXISTS analytics.seed_users;
CREATE TABLE analytics.seed_users (
  user_id text, name text, email text, birth_year int, created_at timestamp
);
SQL

echo "== load real core seed_users (2000 users, 2023-01..2024-12) =="
docker exec -i "$PG" psql -U continuo_svc -d continuo_dbt \
  -c "COPY analytics.seed_users FROM STDIN WITH (FORMAT csv, HEADER true)" \
  < "$ROOT/services/core/seeds/seed_users.csv"

echo "== dbt seed (separate invocation, mirroring continuo's node-by-node orchestration) =="
# fx_transactions_eur references its seed by raw name (analytics.seed_fx_rates_eur),
# so dbt's DAG doesn't order the seed first. In production continuo drives each
# node itself via wise-dbt verbs; the smoke mirrors that by seeding before build.
docker run --rm --network "$NET" \
  -e POSTGRES_HOST="$PG" -e POSTGRES_PORT=5432 \
  -e POSTGRES_DB=continuo_dbt -e POSTGRES_USER=continuo_svc -e POSTGRES_PASSWORD=runner \
  --entrypoint dbt "$IMG" seed --profiles-dir /project

echo "== dbt build (seeds + models + tests) =="
# The image ENTRYPOINT is a local-debug script that ignores its args and always
# runs a hardcoded `dbt run`. Override it so we actually get `dbt build`.
docker run --rm --network "$NET" \
  -e POSTGRES_HOST="$PG" -e POSTGRES_PORT=5432 \
  -e POSTGRES_DB=continuo_dbt -e POSTGRES_USER=continuo_svc -e POSTGRES_PASSWORD=runner \
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

echo "== assert operational_costs_monthly shape =="
assert_scalar "monthly row count (24 months)" 24 \
  "SELECT COUNT(*) FROM analytics.operational_costs_monthly"
assert_scalar "monthly months are all first-of-month" 0 \
  "SELECT COUNT(*) FROM analytics.operational_costs_monthly WHERE EXTRACT(DAY FROM cost_month) <> 1"
assert_scalar "monthly cost_line_count total equals seed rows" 240 \
  "SELECT SUM(cost_line_count) FROM analytics.operational_costs_monthly"
assert_scalar "monthly total equals seed total" t \
  "SELECT ROUND(SUM(total_cost_eur),2) = (SELECT ROUND(SUM(amount::numeric),2) FROM analytics.seed_operational_costs) FROM analytics.operational_costs_monthly"
assert_scalar "category columns sum to the total in every month" 0 \
  "SELECT COUNT(*) FROM analytics.operational_costs_monthly
    WHERE ABS(cogs_eur + rd_eur + ga_eur - total_cost_eur) > 0.01"

echo "== assert operational_cost_per_user shape =="
assert_scalar "cost_per_user has one row per user" 2000 \
  "SELECT COUNT(*) FROM analytics.operational_cost_per_user"
assert_scalar "cost_per_user user_id is unique" 2000 \
  "SELECT COUNT(DISTINCT user_id) FROM analytics.operational_cost_per_user"
assert_scalar "every acquired user is present" 0 \
  "SELECT COUNT(*) FROM analytics.seed_users u
    WHERE NOT EXISTS (SELECT 1 FROM analytics.operational_cost_per_user c
                      WHERE c.user_id = u.user_id::int)"
assert_scalar "every user carries a positive cost" 2000 \
  "SELECT COUNT(*) FROM analytics.operational_cost_per_user WHERE operational_cost_eur > 0"
assert_scalar "acquisition_month is always first-of-month" 0 \
  "SELECT COUNT(*) FROM analytics.operational_cost_per_user
    WHERE EXTRACT(DAY FROM acquisition_month) <> 1"
assert_scalar "distinct acquisition months (all 24 have signups)" 24 \
  "SELECT COUNT(DISTINCT acquisition_month) FROM analytics.operational_cost_per_user"
assert_scalar "users_in_cohort matches the real per-month user count" 0 \
  "SELECT COUNT(*) FROM (
     SELECT c.acquisition_month
     FROM analytics.operational_cost_per_user c
     GROUP BY c.acquisition_month, c.users_in_cohort
     HAVING c.users_in_cohort <> COUNT(*)
   ) bad"

echo "== assert the allocation rule itself =="
# For each cohort: users_in_cohort * per_user_cost must reconstruct that
# month's total cost, allowing a few cents of rounding residual. This is the
# core arithmetic of the model, not just its shape.
assert_scalar "each cohort's allocation reconstructs its month's total" 0 \
  "WITH cohort AS (
       SELECT acquisition_month,
              COUNT(*) AS users, MAX(operational_cost_eur) AS per_user
       FROM analytics.operational_cost_per_user
       GROUP BY 1
   )
   SELECT COUNT(*) FROM cohort
   JOIN analytics.operational_costs_monthly m
     ON m.cost_month = cohort.acquisition_month
   WHERE ABS(cohort.users * cohort.per_user - m.total_cost_eur) > 0.05"

# Every cost month now has a matching acquisition cohort (both run
# 2023-01..2024-12), so nothing is dropped as a whole month; the residual
# below is per-user cent rounding across large cohorts. Assert the
# direction only.
assert_scalar "allocated total never exceeds total costs" t \
  "SELECT (SELECT SUM(operational_cost_eur) FROM analytics.operational_cost_per_user)
        < (SELECT SUM(total_cost_eur) FROM analytics.operational_costs_monthly)"

echo "SMOKE OK"
