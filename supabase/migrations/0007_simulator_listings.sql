-- RevMap: simulator support for creating listings and reading the whole picture.
--
-- Builds on 0006, which provided accounts, trust scores and review posting.
-- This adds the two things a demonstration console still needs:
--
--   * creating a store and a place at an arbitrary point on the map, so a
--     demonstration can invent a location rather than being limited to the
--     twelve seeded places;
--   * one call that returns every place with its aggregate and the reviews
--     behind it, which is what the console renders and what the mobile app
--     shows.
--
-- The same gate applies: simulator_enabled must be 1, and turning it back to 0
-- withdraws all of it. Nothing here can forge a weight -- reviews are still
-- weighted by calculate_review_weight, the same function production uses.
--
-- Apply after 0001..0006. Safe to run more than once.

-- =====================================================================
-- 1. Creating listings
-- =====================================================================

-- Finds a city by name or creates it.
--
-- The console takes coordinates and a name, not a city id: a person creating a
-- listing should never have to pick from a dropdown. The city still needs to
-- exist as a row, because CityTrust is keyed on it and "established in
-- Bengaluru" has to mean the same city next month.
create or replace function sim_upsert_city(p_name text, p_country text default null)
returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_city uuid; v_name text;
begin
  perform sim_require_enabled();
  v_name := btrim(coalesce(p_name, ''));
  if v_name = '' then
    raise exception 'a city name is required' using errcode = '22023';
  end if;

  select id into v_city from cities
   where lower(name) = lower(v_name)
     and (p_country is null or country is null or lower(coalesce(country,'')) = lower(p_country))
   limit 1;
  if v_city is not null then
    return v_city;
  end if;

  insert into cities (name, country) values (v_name, coalesce(p_country, 'Unknown'))
  returning id into v_city;
  return v_city;
end $$;

create or replace function sim_create_store(
  p_name     text,
  p_city_name text,
  p_owner_id uuid default null
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_store uuid; v_owner uuid; v_city uuid;
begin
  perform sim_require_enabled();

  v_city := sim_upsert_city(p_city_name);

  -- Ownership decides whether the owner's own reviews count toward their
  -- store's rating, so it has to be the account that was actually asked for.
  -- It previously was not: a supplied p_owner_id skipped the lookup but was
  -- never assigned, so the store silently fell back to a different account and
  -- owner-conflict exclusion stopped matching.
  if p_owner_id is not null then
    select id into v_owner from profiles where id = p_owner_id;
    if v_owner is null then
      raise exception 'unknown owner' using errcode = 'P0002';
    end if;
  else
    -- No owner named, so fall back to the first demonstration account, and
    -- create one if the console has not made any yet.
    select p.id into v_owner
      from profiles p join auth.users u on u.id = p.id
     where u.email like '%@demo.local' order by p.created_at limit 1;
    if v_owner is null then
      v_owner := sim_create_account('demo-owner', 'owner');
    end if;
  end if;

  insert into stores (owner_id, city_id, name, description, status)
  values (v_owner, v_city, p_name, 'Created in the simulator', 'published')
  returning id into v_store;

  return v_store;
end $$;

-- Creates a place, optionally published immediately.
--
-- A pending place is visible only to its owner, exactly as in production; the
-- console can therefore show both states.
create or replace function sim_create_place(
  p_store_id  uuid,
  p_city_name text,
  p_name      text,
  p_lat       double precision,
  p_lng       double precision,
  p_category  text default 'restaurant',
  p_publish   boolean default true,
  p_country   text default null
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_place uuid; v_city uuid;
begin
  perform sim_require_enabled();

  if p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180 then
    raise exception 'coordinates out of range' using errcode = '22003';
  end if;

  -- Only a genuine place-like magnitude is accepted. A store at 0,0 is almost
  -- always a mis-typed field, and a demonstration does not need it.
  if abs(p_lat) < 0.0001 and abs(p_lng) < 0.0001 then
    raise exception '0,0 is not a real location' using errcode = '22023';
  end if;

  -- The city is created on demand, so a place can be dropped anywhere without
  -- a city existing first.
  v_city := sim_upsert_city(p_city_name, p_country);

  insert into places (store_id, city_id, name, category, description,
                      address_text, latitude, longitude, status,
                      published_at)
  values (p_store_id, v_city, p_name, coalesce(p_category, 'other'),
          'Created in the simulator', '', p_lat, p_lng,
          case when p_publish then 'published' else 'pending' end,
          case when p_publish then now() else null end)
  returning id into v_place;

  -- Seeded display aggregates are only meaningful for the original places; a
  -- simulated one starts with none and earns its rating from real review math.
  return v_place;
end $$;

-- =====================================================================
-- 2. Reading the whole picture
-- =====================================================================

create or replace function sim_cities()
returns table (id uuid, name text, country text)
language plpgsql security definer set search_path = public, extensions as $$
begin
  -- The read functions are gated too. Leaving them open would mean switching
  -- the simulator off still exposed its surface through these endpoints.
  perform sim_require_enabled();
  return query select c.id, c.name, c.country from cities c order by c.name;
end $$;

create or replace function sim_stores()
returns table (id uuid, name text, city text, place_count bigint)
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform sim_require_enabled();
  return query
    select s.id, s.name, c.name,
           (select count(*) from places p where p.store_id = s.id)
    from stores s join cities c on c.id = s.city_id
    order by s.name;
end $$;

-- One call that returns every place with its aggregate, so the console can
-- render the same figures the mobile app shows.
create or replace function sim_overview()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform sim_require_enabled();
  -- RETURNS jsonb is a scalar, so this is RETURN, not RETURN QUERY.
  return
  (select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
  from (
    select
      p.id, p.name, p.category, p.latitude, p.longitude, p.status,
      s.name as store_name,
      round(pr.adjusted_rating::numeric, 2) as adjusted_rating,
      round(coalesce(pr.effective_review_count, 0)::numeric, 2) as effective_count,
      coalesce(pr.raw_review_count, 0) as raw_count,
      round(place_confidence(p.id)::numeric, 3) as confidence
    from places p
    left join stores s on s.id = p.store_id
    cross join lateral place_rating(p.id) pr
    order by p.name
  ) t);
end $$;

-- Every review on a place, with the weight it actually carried.
--
-- This is the audit view: it shows that the stored weight is the formula's
-- output and not a number the client supplied.
create or replace function sim_place_reviews(p_place_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform sim_require_enabled();
  return
  (select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
  from (
    select
      r.id, r.rating, r.text, r.status, r.created_at,
      round(r.user_trust::numeric, 1)   as user_trust,
      round(r.city_trust::numeric, 1)   as city_trust,
      round(r.review_trust::numeric, 1) as review_trust,
      round(r.review_weight::numeric, 4) as review_weight,
      (r.visit_proof_id is not null)    as verified_visit,
      (r.explanation->>'source')       as source
    from reviews r
    where r.place_id = p_place_id
    order by r.created_at desc
  ) t);
end $$;

comment on function sim_overview() is
  'Every place with the aggregate the mobile app displays: adjusted rating, '
  'effective review count, raw count and confidence.';

-- =====================================================================
-- Access
-- =====================================================================

grant execute on function sim_create_store(text, text, uuid) to authenticated;
grant execute on function sim_create_place(uuid, text, text, double precision, double precision, text, boolean, text) to authenticated;
grant execute on function sim_upsert_city(text, text) to authenticated;
grant execute on function sim_cities()   to authenticated;
grant execute on function sim_stores()   to authenticated;
grant execute on function sim_overview() to authenticated;
grant execute on function sim_place_reviews(uuid) to authenticated;

revoke execute on all functions in schema public from anon;
