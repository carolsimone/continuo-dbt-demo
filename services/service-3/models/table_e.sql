{{ config(materialized='table', tags=['e2e-schedule']) }}
SELECT *
FROM analytics.table_b
JOIN analytics.table_c USING (id)
JOIN analytics.wopwop USING (id)
