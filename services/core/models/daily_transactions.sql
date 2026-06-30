{{ config(materialized='table'), tags=['e2e-schedule'])}}

-- Basic union of transaction types, valued in EUR.
-- NOTE: analytics.fx_transactions_eur is produced by the *finance* service (a
-- separate dbt project). Per the repo's cross-service convention it is referenced
-- by its raw schema-qualified name and must NOT be turned into a ref() call.
-- See README.md "Cross-service references".

SELECT
    transaction_id,
    user_id,
    ROUND(amount::numeric, 2) AS amount_eur,   -- card amounts treated as already-EUR
    created_at,
    'card' AS source
FROM {{ ref('seed_card_transactions') }}

UNION ALL

SELECT
    transaction_id,
    user_id,
    amount_eur,
    created_at,
    'fx' AS source
FROM analytics.fx_transactions_eur
