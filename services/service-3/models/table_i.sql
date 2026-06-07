{{ config(materialized='table', tags=['e2e-schedule']) }}
SELECT * FROM analytics.table_g JOIN analytics.table_h USING (id)
