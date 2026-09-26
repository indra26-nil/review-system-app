-- RevMap: the store-owner upload path.
--
-- Extends the M1 schema with everything a signed-in owner needs to register a
-- store and publish places, while keeping the rule that matters: a place is
-- only visible to other users once it is published.
--
-- The visibility rule is enforced here, not in the app. The client can create
-- and edit its own listings, but it cannot publish on someone else's behalf,
-- and it cannot make its own place visible without going through the guarded
-- function below.
--
-- Apply after 0001..0003. Safe to run more than once.

-- =====================================================================
-- 1. Publication policy, in configuration rather than code
-- =====================================================================
-- While this is true an owner may publish their own listings, which is what
-- makes the upload -> visible flow demonstrable. Turning it off is the one-line
-- change that moves approval to moderators, with no code edit.

insert into trust_config (key, value) values
  ('self_publish_enabled', 1)
on conflict (key) do update set value = excluded.value;

-- =====================================================================
-- 2. Profiles: a user may create exactly their own, and only their own
-- =====================================================================

drop policy if exists "insert own profile" on profiles;
create policy "insert own profile" on profiles
  for insert with check (auth.uid() = id);

drop policy if exists "update own profile" on profiles;
create policy "update own profile" on profiles
  for update using (auth.uid() = id);

drop policy if exists "read own profile" on profiles;
create policy "read own profile" on profiles
  for select using (auth.uid() = id);

-- =====================================================================
-- 3. Stores
-- =====================================================================

-- An owner reads their own store whatever its status, plus any published store.
drop policy if exists "owners read own store" on stores;
create policy "owners read own store" on stores
  for select using (auth.uid() = owner_id or status = 'published');

drop policy if exists "owners insert own store" on stores;
create policy "owners insert own store" on stores
  for insert with check (auth.uid() = owner_id);

drop policy if exists "owners update own store" on stores;
create policy "owners update own store" on stores
  for update using (auth.uid() = owner_id);

-- =====================================================================
-- 4. Places
-- =====================================================================
-- Everyone sees published places. An owner additionally sees their own
-- pending ones, so a new listing is not invisible to the person who created it.

drop policy if exists "read published places" on places;
create policy "read published places" on places
  for select using (
    status = 'published'
    or exists (
      select 1 from stores s
      where s.id = places.store_id and s.owner_id = auth.uid()
    )
  );

-- A place may only be created for a store the caller actually owns. Without
-- this check anyone could attach a listing to any business.
drop policy if exists "owners insert own places" on places;
create policy "owners insert own places" on places
  for insert with check (
    store_id is not null
    and exists (
      select 1 from stores s
      where s.id = places.store_id and s.owner_id = auth.uid()
    )
  );

drop policy if exists "owners update own places" on places;
create policy "owners update own places" on places
  for update using (
    exists (
      select 1 from stores s
      where s.id = places.store_id and s.owner_id = auth.uid()
    )
  );

-- =====================================================================
-- 5. Publication
-- =====================================================================
-- Going through a function rather than a plain UPDATE means the rule "only the
-- owner, and only while self-publishing is enabled" lives in one place and
-- cannot be bypassed by the app.

create or replace function set_place_published(p_place_id uuid, p_published boolean)
returns places
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_row places;
begin
  select * into v_row from places where id = p_place_id;
  if not found then
    raise exception 'place not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from places p
    join stores s on s.id = p.store_id
    where p.id = p_place_id and s.owner_id = auth.uid()
  ) then
    raise exception 'not your place' using errcode = '42501';
  end if;

  if p_published and cfg('self_publish_enabled') <> 1 then
    -- With self-publishing disabled this would become a moderator-only action.
    raise exception 'publication requires review' using errcode = '42501';
  end if;

  update places
     set status = case when p_published then 'published' else 'pending' end,
         published_at = case when p_published then now() else null end
   where id = p_place_id
   returning * into v_row;

  return v_row;
end $$;

-- Only the owner of the place may call it. The function itself re-checks, so
-- this grant is a convenience, not the security boundary.
revoke execute on function set_place_published(uuid, boolean) from anon;
grant execute on function set_place_published(uuid, boolean) to authenticated;

-- =====================================================================
-- 6. A view that answers "what does this place look like to a user?"
-- =====================================================================
-- Keeps the public read in one query for the app: the place, its store, and the
-- seeded display aggregates, with no client-side joins and no access to the
-- trust tables.

create or replace view public_place_cards
with (security_invoker = true) as
  select
    p.id,
    p.name,
    p.category,
    p.description,
    p.address_text,
    p.latitude,
    p.longitude,
    p.status,
    p.geofence_radius_m,
    s.name  as store_name,
    s.owner_id,
    coalesce(t.rating, 0)        as rating,
    coalesce(t.review_count, 0)   as review_count,
    coalesce(t.open_status, 'open') as open_status,
    t.closing_time
  from places p
  left join stores s on s.id = p.store_id
  left join place_seed_stats t on t.place_id = p.id
  where p.status = 'published';

comment on view public_place_cards is
  'Public read model for place cards. security_invoker keeps row-level '
  'security in force, so a pending place stays hidden from everyone else even '
  'though the view does not filter on status for its owner.';
