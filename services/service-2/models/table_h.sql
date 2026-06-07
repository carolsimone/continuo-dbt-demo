{{ config(materialized='table', tags=['e2e-schedule']) }}
SELECT * FROM analytics.table_e JOIN analytics.table_f USING (id)
