{{ config(materialized='table', tags=['daily']) }}
SELECT *, missing_audit_column FROM analytics.table_k
