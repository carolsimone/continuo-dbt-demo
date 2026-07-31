{{ config(materialized='view', tags=['daily']) }}
select * from {{ ref('operation_cost_per_user')}}
