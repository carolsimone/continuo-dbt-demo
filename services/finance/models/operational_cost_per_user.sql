{{ config(materialized='table') }}

-- Per-user operational cost: each month's total operational cost divided
-- evenly across the users acquired that month. One row per user_id.
--
-- Worked example: if a month's costs totalled 100 EUR and we acquired 100
-- users that month, each of those users carries 1 EUR.
--
-- The user source is core's seed_users, read as a raw schema-qualified name
-- per the repo's cross-service rule (never ref() across services) -- the same
-- pattern fx_transactions_eur uses for analytics.seed_fx_transactions. dbt
-- does not see the dependency; build ordering across services is the
-- platform's concern.
--
-- Two deliberate behaviours:
--   * Costs in a month with zero signups stay UNALLOCATED -- there is no user
--     to attach them to and they simply produce no row here (10 of 36 months
--     today). So SUM(operational_cost_eur) < SUM(total_cost_eur), by design.
--     Query operational_costs_monthly for the full cost picture. A cost month
--     drifting OUTSIDE the acquisition window entirely is a data bug and is
--     caught by assert_operational_costs_within_acquisition_window.
--   * users_in_cohort is carried as a column so a reader can reconstruct the
--     division without re-deriving the cohort.
--
-- Rounding to cents means a cohort's per-user costs can sum a few cents off
-- the month's total. Accepted; a residual-allocation scheme is not worth it.

WITH acquisitions AS (

    SELECT
        user_id::int                                      AS user_id,
        created_at::timestamp                             AS acquired_at,
        DATE_TRUNC('month', created_at::timestamp)::date  AS acquisition_month
    FROM analytics.seed_users

),

cohort_size AS (

    -- How many users were acquired in each month -- the divisor. No channel
    -- dimension: operational costs are company-wide (spec decision 4).
    SELECT
        acquisition_month,
        COUNT(*) AS users_acquired
    FROM acquisitions
    GROUP BY 1

)

SELECT
    a.user_id,
    a.acquired_at,
    a.acquisition_month,
    c.users_acquired                                AS users_in_cohort,
    ROUND(m.total_cost_eur / c.users_acquired, 2)   AS operational_cost_eur
FROM acquisitions a
INNER JOIN cohort_size c
    ON c.acquisition_month = a.acquisition_month
INNER JOIN {{ ref('operational_costs_monthly') }} m
    ON m.cost_month = a.acquisition_month
