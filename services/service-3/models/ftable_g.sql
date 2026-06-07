{{ config(materialized='table', tags=['e2e-schedule-failure']) }}
SELECT a.id
FROM analytics.ftable_a a
LEFT JOIN analytics.ftable_b b ON a.id = b.id
