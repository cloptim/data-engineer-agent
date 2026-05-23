---
name: add-dbt-model
description: Use this skill when the user wants to add or modify a dbt model (staging or mart). Triggers include "create a staging model", "add a mart for X", "build a daily aggregate", "transform the raw data into Y". Produces a SQL file plus the matching schema.yml test entries following project naming and PII conventions.
---

# Add a dbt model

## Two flavors

### Staging (`stg_<source>__<entity>.sql`)

Light typing, renaming, and PII hashing. **Never aggregate in staging.** One row in → one row out.

Required:
- Cast types explicitly. `cast(x as integer)`, not implicit.
- Hash any column matching the PII regex (`email`, `phone`, `ssn`, `dob`, `address`):
  ```sql
  md5(lower(trim(email))) as email_hash,
  ```
  And do not select the raw column.
- Add a `loaded_at` timestamp: `current_timestamp as loaded_at`.

Template:
```sql
with source as (
    select * from {{ source('<source>', '<raw_table>') }}
),
renamed as (
    select
        cast(id as integer) as <entity>_id,
        cast(created_at as timestamp) as created_at,
        -- PII columns hashed here
        md5(lower(trim(email))) as email_hash,
        current_timestamp as loaded_at,
    from source
)
select * from renamed
```

### Mart (`<domain>_<grain>.sql`)

Business-facing aggregate or wide table. Examples: `orders_daily`, `customers_lifetime`,
`revenue_by_product_monthly`.

Required:
- A single primary key column. Document it in the schema.yml.
- `not_null` + `unique` tests on the PK.
- A `dbt_updated_at` column: `current_timestamp as dbt_updated_at`.
- Materialize as `table` (not `view`) unless the user specifies otherwise.

Template config block at top:
```sql
{{ config(materialized='table') }}
```

## schema.yml entry (always add this)

For every model, append to the directory's `schema.yml`:

```yaml
  - name: <model_name>
    description: "<one-sentence purpose>"
    columns:
      - name: <pk_column>
        description: "Primary key."
        tests:
          - not_null
          - unique
      # ... other columns documented
```

If `schema.yml` doesn't exist in the directory yet, create it with the standard header:
```yaml
version: 2
models:
```

## Things the hook will catch (don't make these mistakes)

- Selecting raw PII columns in staging - `pii-check` hook blocks the write.
- Using `select *` in a mart - flagged by `sqlfluff`.
- Forgetting tests on the PK - caught by the pre-commit hook running `dbt parse`.
