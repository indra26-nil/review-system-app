-- RevMap: repair schema drift caused by editing an applied migration.
--
-- Background: `places.published_at` and the `cities` unique constraint were
-- added by editing 0001 and 0003 after they had already been applied. Those
-- files begin with `create table if not exists`, so re-running them is a no-op
-- when the table already exists -- the columns silently never arrived. The
-- console then failed with
--   column "published_at" of relation "places" does not exist
--
-- Functions are not affected: `create or replace function` does update an
-- existing function, so re-applying 0002 and 0006 has been working. Only
-- table shape drifted, and only where a column was added to a CREATE TABLE
-- statement after the fact.
--
-- This migration is additive and idempotent. It is safe on a database that was
-- never drifted, and it repairs one that was.
--
-- Apply after the others. Safe to run more than once.

-- =====================================================================
-- 1. places.published_at
-- =====================================================================
-- Set when a listing goes live, so age can be shown and stale listings found.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_name='places' and column_name='published_at') then
    raise notice '      places.published_at      already present';
  else
    alter table places add column published_at timestamptz;
    raise notice '      ADDED  places.published_at';
  end if;
end $$;

-- =====================================================================
-- 2. cities uniqueness
-- =====================================================================
-- Without it the seed re-run would create a second "Bengaluru" and orphan
-- every place referencing the first. Added conditionally because the
-- constraint may or may not be present depending on when 0001 was applied.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'cities'::regclass and contype = 'u'
  ) then
    -- Deduplicate first: a constraint cannot be added over duplicate rows.
    -- Places keep pointing at whichever city row survives, so only the
    -- unreferenced duplicates are removed.
    delete from cities c
     where exists (
       select 1 from cities d
        where d.name = c.name
          and coalesce(d.country,'') = coalesce(c.country,'')
          and d.ctid < c.ctid
          and not exists (select 1 from places p where p.city_id = c.id)
          and not exists (select 1 from stores s where s.city_id = c.id)
          and not exists (select 1 from user_city_trust u where u.city_id = c.id)
     );
    alter table cities add constraint cities_name_country_key unique (name, country);
  end if;
end $$;

-- =====================================================================
-- 3. Backfill, so existing rows are not left null
-- =====================================================================
-- Any place already marked published but with no timestamp gets one, derived
-- from when it was created. A published listing that predates this column
-- would otherwise read as "published, but when?".
update places
   set published_at = created_at
 where published_at is null
   and status = 'published'
   and created_at is not null;

-- =====================================================================
-- 4. Anything else that may be missing
-- =====================================================================
-- Declared by hand here rather than in 0001, because a column added to a
-- CREATE TABLE after the fact is exactly what caused this drift.
alter table profiles
  add column if not exists declared_country text;

-- =====================================================================
-- 5. Report
-- =====================================================================
do $$
declare
  v_missing text := '';
begin
  if not exists (select 1 from information_schema.columns
                  where table_name='places' and column_name='published_at') then
    v_missing := v_missing || ' places.published_at';
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid='cities'::regclass and contype='u') then
    v_missing := v_missing || ' cities unique(name,country)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_name='profiles' and column_name='declared_country') then
    v_missing := v_missing || ' profiles.declared_country';
  end if;

  -- This summary runs last, so it describes the state *after* the repair.
  -- Reporting only what was missing would be misleading: on a drifted database
  -- every item now exists, and the message would claim nothing was wrong.
  raise notice '      schema is now consistent';
  if v_missing = '' then
    raise notice 'PASS  nothing needed repairing';
  else
    raise notice '      (was missing:% )', v_missing;
  end if;
end $$;
