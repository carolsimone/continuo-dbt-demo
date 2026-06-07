{{ config(materialized='table', tags=['e2e-schedule-failure']) }}
SELECT id FROM analytics.ftable_g
