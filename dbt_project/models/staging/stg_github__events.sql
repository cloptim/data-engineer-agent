-- stg_github__events.sql
-- Staging model for GitHub events. One row in (from raw) = one row out.
-- PII conventions applied: the actor's login is kept (public handle), but if we ever
-- start ingesting webhook payloads with private email addresses, this is where they'd
-- be hashed. The pii-check hook will block a future edit that forgets.

with source as (

    select *
    from {{ source('github', 'events_raw') }}

),

renamed as (

    select
        cast(id as bigint) as event_id,
        cast(type as varchar) as event_type,
        cast(actor_login as varchar) as actor_login,
        cast(repo_name as varchar) as repo_name,
        cast(created_at as timestamp) as event_at,
        cast(public as boolean) as is_public,
        -- payload kept as raw JSON for downstream extraction in marts
        cast(payload as varchar) as payload_json,
        current_timestamp as loaded_at,
    from source

)

select * from renamed
