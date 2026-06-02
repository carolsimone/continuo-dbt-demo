{{ config(materialized='table') }}
SELECT id FROM analytics.ftable_g
