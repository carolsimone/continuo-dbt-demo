-- Regression guard for the EUR conversion contract:
--   amount_eur must equal round(amount * rate_to_eur, 2), and rate_to_eur must be positive.
-- Returns offending rows; the test passes only when there are none.
SELECT
    transaction_id,
    amount,
    rate_to_eur,
    amount_eur
FROM {{ ref('fx_transactions_eur') }}
WHERE amount_eur <> ROUND((amount * rate_to_eur)::numeric, 2)
   OR rate_to_eur <= 0
