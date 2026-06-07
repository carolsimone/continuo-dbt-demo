{{ config(materialized='table', tags=['e2e-schedule']) }}
SELECT * FROM analytics.table_a JOIN analytics.table_b USING (id)
