{{ config(materialized='table', tags=['e2e-schedule'])}}
SELECT * FROM analytics.table_d WHERE 1 = 1
