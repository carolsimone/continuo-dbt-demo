{{ config(materialized='table') }}
SELECT * FROM analytics.table_g JOIN analytics.table_h USING (id)
