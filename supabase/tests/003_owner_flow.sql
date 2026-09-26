-- RevMap: the store-owner upload path, verified.
--
-- Behaviour under test:
--   1. An owner registers a store and adds a place.
--   2. That place is invisible to other users while pending.
--   3. Once published, every user can see it.
--   4. A user cannot attach a place to someone else's store, publish someone
--      else's place, or promote themselves to owner.
--
-- IMPORTANT: the visibility assertions run with `set local role authenticated`.
-- psql connects as postgres, a superuser, which bypasses row-level security
-- entirely -- so a test run that way "passes" no matter what the policies say.
-- The role switch is the entire point of this file.
--
--   psql -d revamp -f supabase/tests/003_owner_flow.sql

\pset footer off

do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin noinherit; end if;
end $$;

create schema if not exists test_helper;

-- Fixtures are created as the table owner (security definer), deliberately:
-- setting up data must not depend on the policies under test.
create or replace function test_helper.make_user(p_role text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  insert into auth.users (email) values (p_role || '-' || gen_random_uuid() || '@example.com') returning id into v;
  insert into profiles (id, handle, display_name, role) values (v, p_role || '-' || substr(v::text,1,8), p_role, p_role);
  return v;
end $$;

drop table if exists test_helper.fx;
create table test_helper.fx (owner uuid, store uuid, place uuid, other uuid);

-- Plain sequential inserts: PostgreSQL does not allow INSERT inside a LATERAL
-- join, which is what the first version of this fixture tried.
do $$
declare v_owner uuid; v_other uuid; v_store uuid; v_place uuid; v_city uuid;
begin
  v_owner := test_helper.make_user('owner');
  v_other := test_helper.make_user('user');
  select id into v_city from cities limit 1;

  insert into stores (owner_id, city_id, name, description, status)
  values (v_owner, v_city, 'Corner Cafe', 'A test listing', 'published')
  returning id into v_store;

  insert into places (store_id, city_id, name, category, address_text, latitude, longitude, status)
  values (v_store, v_city, 'Corner Cafe', 'restaurant', '12 MG Road', 12.9716, 77.5946, 'pending')
  returning id into v_place;

  insert into test_helper.fx (owner, store, place, other) values (v_owner, v_store, v_place, v_other);
end $$;

\echo '=== 1. Owner uploads a place; it starts pending ==='

do $$
declare st text;
begin
  select status into st from places where id = (select place from test_helper.fx);
  if st = 'pending' then
    raise notice 'PASS  a new place starts pending, so it is not yet public';
  else
    raise exception 'FAIL  a new place started as %', st;
  end if;
end $$;

\echo ''
\echo '=== 2. Visibility, checked as a real (non-superuser) role ==='

do $$
declare n int; v_place uuid; v_owner uuid; v_other uuid;
begin
  select place, owner, other into v_place, v_owner, v_other from test_helper.fx;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  set local role authenticated;
  select count(*) into n from places where id = v_place;
  reset role;
  if n = 1 then
    raise notice 'PASS  the owner can still see their own pending place';
  else
    raise exception 'FAIL  the owner lost sight of their own listing';
  end if;

  perform set_config('request.jwt.claim.sub', v_other::text, true);
  set local role authenticated;
  select count(*) into n from places where id = v_place;
  reset role;
  if n = 0 then
    raise notice 'PASS  another user cannot see a pending place';
  else
    raise exception 'FAIL  a pending place is visible to the public';
  end if;
end $$;

\echo ''
\echo '=== 3. Publishing makes it visible to everyone ==='

do $$
declare n int; st text; v_place uuid; v_owner uuid; v_other uuid;
begin
  select place, owner, other into v_place, v_owner, v_other from test_helper.fx;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  set local role authenticated;
  perform set_place_published(v_place, true);
  reset role;

  select status into st from places where id = v_place;
  if st = 'published' then
    raise notice 'PASS  the owner published their own place';
  else
    raise exception 'FAIL  publication did not take effect';
  end if;

  if (select published_at from places where id = v_place) is not null then
    raise notice 'PASS  published_at recorded';
  end if;

  perform set_config('request.jwt.claim.sub', v_other::text, true);
  set local role authenticated;
  select count(*) into n from places where id = v_place;
  reset role;
  if n = 1 then
    raise notice 'PASS  the place is now visible to another user';
  else
    raise exception 'FAIL  a published place is still hidden from other users';
  end if;
end $$;

\echo ''
\echo '=== 4. One user cannot touch another''s listing ==='

do $$
declare v_store uuid; v_place uuid; v_other uuid; v_err text;
begin
  select store, place, other into v_store, v_place, v_other from test_helper.fx;

  v_err := null;
  perform set_config('request.jwt.claim.sub', v_other::text, true);
  set local role authenticated;
  begin
    insert into places (store_id, city_id, name, latitude, longitude, status)
    values (v_store, (select id from cities limit 1), 'Hijacked', 1, 1, 'published');
  exception when others then v_err := left(sqlerrm, 50);
  end;
  reset role;
  if v_err is not null then
    raise notice 'PASS  cannot add a place to another owner''s store (%s)', v_err;
  else
    raise exception 'FAIL  a user attached a place to somebody else''s store';
  end if;

  v_err := null;
  perform set_config('request.jwt.claim.sub', v_other::text, true);
  set local role authenticated;
  begin
    perform set_place_published(v_place, false);
  exception when others then v_err := left(sqlerrm, 50);
  end;
  reset role;
  if v_err is not null then
    raise notice 'PASS  cannot unpublish another owner''s place (%s)', v_err;
  else
    raise exception 'FAIL  a user modified somebody else''s place';
  end if;

  -- Changing somebody else's role must be impossible. The fixture owner is
  -- already an owner, so try to demote them: if a plain user can do that, they
  -- can certainly promote anyone.
  perform set_config('request.jwt.claim.sub', v_other::text, true);
  set local role authenticated;
  v_err := null;
  begin
    update profiles set role = 'user' where id = (select owner from test_helper.fx);
  exception when others then v_err := left(sqlerrm, 45);
  end;
  reset role;
  if (select role from profiles where id = (select owner from test_helper.fx)) <> 'owner' then
    raise exception 'FAIL  a plain user changed somebody else''s role';
  else
    raise notice 'PASS  cannot change another user''s role (%s)', coalesce(v_err, 'blocked by RLS');
  end if;

  -- Nor can a plain user rewrite their own role after sign-up. Choosing
  -- "store owner" at sign-up is supported; silently escalating later is not.
  perform set_config('request.jwt.claim.sub', v_other::text, true);
  set local role authenticated;
  v_err := null;
  begin
    update profiles set role = 'owner' where id = v_other;
  exception when others then v_err := left(sqlerrm, 45);
  end;
  reset role;
  if (select role from profiles where id = v_other) = 'owner' then
    raise exception 'FAIL  a user promoted themselves to owner after sign-up';
  else
    raise notice 'PASS  cannot self-promote after sign-up (%s)', coalesce(v_err, 'blocked');
  end if;

  -- ...while ordinary self-service edits still work.
  perform set_config('request.jwt.claim.sub', v_other::text, true);
  set local role authenticated;
  update profiles set display_name = 'Renamed' where id = v_other;
  reset role;
  if (select display_name from profiles where id = v_other) = 'Renamed' then
    raise notice 'PASS  a user can still edit their own display name';
  else
    raise exception 'FAIL  ordinary profile edits are blocked';
  end if;
end $$;

\echo ''
\echo '=== 5. The public read model ==='

do $$
declare n int;
begin
  select count(*) into n from public_place_cards;
  if n > 0 then
    raise notice 'PASS  public_place_cards returns %s published place(s)', n;
  else
    raise exception 'FAIL  the public read model is empty';
  end if;
end $$;

drop table if exists test_helper.fx;
