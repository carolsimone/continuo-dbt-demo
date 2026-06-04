{{ config(materialized='table') }}
SELECT id FROM analytics.xcheck_up
