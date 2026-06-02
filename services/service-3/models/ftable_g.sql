{{ config(materialized='table') }}
SELECT a.id
FROM analytics.ftable_a a
LEFT JOIN public.wrong_name_2 w ON a.id = w.id
