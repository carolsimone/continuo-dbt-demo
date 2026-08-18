-- Revenue is a sum of fees, which are never negative (no refunds or
-- chargebacks in this dataset). Passes when it returns no rows.

SELECT
    user_id,
    revenue_eur,
    gross_volume_eur
FROM {{ ref('revenue_per_user') }}
WHERE revenue_eur < 0
   OR gross_volume_eur < 0
