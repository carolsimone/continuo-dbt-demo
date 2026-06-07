{{ config(materialized='table', tags=['xcheck']) }}
SELECT id FROM analytics.xcheck_up
