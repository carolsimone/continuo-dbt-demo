{{ config(materialized='table', tags=['daily']) }}

-- Company operational costs rolled up to one row per month -- the "what did
-- running the company cost this month" table whose total
-- operational_cost_per_user divides across the users acquired that month.
--
-- Category detail (COGS / R&D / G&A) lives here as breakdown columns; the
-- per-user model deliberately carries only the total (spec decision 3).
--
-- All amounts are EUR (pinned by the accepted_values test on the seed's
-- currency column in schema.yml), so no conversion is needed here.

SELECT
    DATE_TRUNC('month', cost_date::timestamp)::date                  AS cost_month,
    ROUND(SUM(amount::numeric), 2)                                   AS total_cost_eur,
    ROUND(SUM(amount::numeric) FILTER (WHERE category = 'COGS'), 2)  AS cogs_eur,
    ROUND(SUM(amount::numeric) FILTER (WHERE category = 'R&D'), 2)   AS rd_eur,
    ROUND(SUM(amount::numeric) FILTER (WHERE category = 'G&A'), 2)   AS ga_eur,
    COUNT(*)                                                         AS cost_line_count
FROM {{ ref('seed_operational_costs') }}
GROUP BY 1
