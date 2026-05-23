-- events_daily.sql
-- Daily aggregate of GitHub events by repo and event type.
-- Primary key: (event_date, repo_name, event_type).

{{ config(materialized='table') }}

with events as (

    select * from {{ ref('stg_github__events') }}

),

daily as (

    select
        cast(event_at as date) as event_date,
        repo_name,
        event_type,
        count(*) as event_count,
        count(distinct actor_login) as unique_actors,
        current_timestamp as dbt_updated_at,
    from events
    group by 1, 2, 3

)

select * from daily
