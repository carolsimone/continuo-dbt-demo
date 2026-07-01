{{ config(materialized='table'), tags=['e2e-schedule']) }}

SELECT
    t.transaction_id,
    t.user_id,
    t.amount,
    t.currency_from,
    t.currency_to,
    t.rate,
    t.created_at,
    r.rate_to_eur,
    ROUND((t.amount * r.rate_to_eur)::numeric, 2) AS amount_eur
FROM analytics.seed_fx_transactions t
LEFT JOIN {{ ref('seed_fx_rates_eur') }} r
    ON t.currency_from = r.currency
   AND t.created_at::date = r.rate_date
