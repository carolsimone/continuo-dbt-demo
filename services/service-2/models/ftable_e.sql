{{ config(materialized='table') }}
SELECT c.id
FROM analytics.ftable_c c
LEFT JOIN analytics.ftable_a a ON c.id = a.id
