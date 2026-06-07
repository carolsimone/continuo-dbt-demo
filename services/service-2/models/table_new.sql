{{ config(materialized='view') }}
SELECT * FROM analytics.table_e
