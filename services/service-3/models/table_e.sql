{{ config(materialized='table') }}
SELECT * FROM analytics.table_b JOIN analytics.table_c USING (id)
