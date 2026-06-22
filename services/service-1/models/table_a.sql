{{ config(materialized='table', tags=['e2e-schedule']) }}
SELECT * FROM {{ ref('seed_table_1') }} WHERE 1=1
