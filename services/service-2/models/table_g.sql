{{ config(materialized='table') }}
SELECT * FROM analytics.table_d JOIN analytics.table_e USING (id)
