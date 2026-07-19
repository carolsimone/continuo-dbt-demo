{{ config(materialized='table', tags=['daily']) }}

-- Per-user acquisition cost: each channel-month's spend divided evenly across
-- the users that channel acquired that month. One row per user_id.
--
-- Worked example: a user acquired via affiliate in June 2023, where affiliate
-- spent 100 EUR that month and acquired 10 users, carries 10 EUR.
--
-- Two deliberate behaviours:
--   * Every acquired user gets a row. organic and referral have no spend by
--     nature, so they cost 0 rather than NULL -- we know the value, it is zero.
--     They will gain *operational* costs as a separate component when the LTV
--     model lands; that must not overwrite marketing_cost_eur.
--   * Spend in a channel-month that acquired nobody stays UNALLOCATED -- it has
--     no user to attach to and simply produces no row here. So
--     SUM(marketing_cost_eur) < SUM(marketing_spend_monthly.spend_eur), by
--     design. Query marketing_spend_monthly for the full spend picture.
--
-- Rounding to cents means a cohort's per-user costs can sum to a few cents off
-- that cohort's spend. Accepted; a residual-allocation scheme is not worth it.

WITH acquisitions AS (

    SELECT
        user_id::int                                       AS user_id,
        channel,
        campaign,
        acquired_at::timestamp                             AS acquired_at,
        DATE_TRUNC('month', acquired_at::timestamp)::date  AS acquisition_month
    FROM {{ ref('seed_user_acquisition') }}

),

cohort_size AS (

    -- How many users each channel acquired in each month -- the divisor.
    SELECT
        channel,
        acquisition_month,
        COUNT(*) AS users_acquired
    FROM acquisitions
    GROUP BY 1, 2

),

paid_channels AS (

    -- A channel is "paid" iff we have ever spent on it. Derived from the data
    -- rather than hardcoded, so adding a channel to the spend seed is enough.
    SELECT DISTINCT channel
    FROM {{ ref('marketing_spend_monthly') }}

)

SELECT
    a.user_id,
    a.channel,
    a.campaign,
    a.acquired_at,
    a.acquisition_month,
    (p.channel IS NOT NULL)                                 AS channel_is_paid,
    COALESCE(ROUND(s.spend_eur / c.users_acquired, 2), 0)   AS marketing_cost_eur
FROM acquisitions a
INNER JOIN cohort_size c
    ON  c.channel           = a.channel
    AND c.acquisition_month = a.acquisition_month
LEFT JOIN paid_channels p
    ON p.channel = a.channel
LEFT JOIN {{ ref('marketing_spend_monthly') }} s
    ON  s.channel     = a.channel
    AND s.spend_month = a.acquisition_month
