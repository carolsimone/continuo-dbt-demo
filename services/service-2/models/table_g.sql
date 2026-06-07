{{ config(materialized='table', tags=['e2e-schedule']) }}
SELECT * FROM analytics.table_d JOIN analytics.table_e USING (id)
