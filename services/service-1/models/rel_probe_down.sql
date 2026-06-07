{{ config(materialized='table', tags=['rel-probe']) }}
SELECT id FROM {{ ref('rel_probe_up') }}
