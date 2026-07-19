{{ config(materialized='view', tags=['e2e-schedule']) }}
SELECT * FROM analytics.table_a WHERE 1=1
