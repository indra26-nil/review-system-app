-- RevMap: creating listings from the simulator console.
--
-- The regression this guards against is subtle: on a permissive local stub,
-- auth.users.id has a database default, so `insert into auth.users (email)`
-- works. Supabase generates the id in GoTrue, so it has NO default and the
-- same insert fails with
--   null value in column "id" of relation "users" violates not-null constraint
-- The stub in .toolchain/auth_stub.sql now matches Supabase, so this is
-- reproducible locally.

\pset footer off

do $$ begin
  if not exists (select 1 from pg_roles where rolname='authenticated') then
    create role authenticated nologin noinherit;
  end if;
end $$;

update trust_config set value = 1 where key = 'simulator_enabled';

\echo '=== Creating a store provisions an owner without erroring ==='

do $$
declare
  v_account uuid;
  v_store   uuid;
  v_place   uuid;
  n         int;
begin
  select sim_create_account('test-owner', 'owner') into v_account;
  if v_account is null then
    raise exception 'FAIL  sim_create_account returned null';
  end if;
  raise notice 'PASS  sim_create_account returned a uuid';

  -- This is the call that failed in the console.
  select sim_create_store('Corner Cafe', (select id from cities limit 1)) into v_store;
  if v_store is null then
    raise exception 'FAIL  sim_create_store returned null';
  end if;
  raise notice 'PASS  sim_create_store worked';

  select sim_create_place(v_store, (select id from cities limit 1),
                          'Corner Cafe', 12.9716, 77.5946,
                          'restaurant', true) into v_place;
  if v_place is null then
    raise exception 'FAIL  sim_create_place returned null';
  end if;
  raise notice 'PASS  sim_create_place worked at 12.97,77.59';

  select jsonb_array_length(sim_overview()) into n;
  raise notice 'PASS  overview lists % place(s)', n;
end $$;

\echo ''
\echo '=== Bad input is refused rather than stored ==='

do $$
declare v_store uuid;
begin
  select sim_create_store('Refusal Test', (select id from cities limit 1)) into v_store;
  begin
    perform sim_create_place(v_store, (select id from cities limit 1), 'Nowhere', 0, 0);
    raise exception 'FAIL  0,0 was accepted';
  exception when others then
    if sqlerrm like '%not a real location%' then
      raise notice 'PASS  a 0,0 location is refused';
    else raise; end if;
  end;

  begin
    perform sim_create_place(v_store, (select id from cities limit 1), 'Bad', 91, 0);
    raise exception 'FAIL  latitude 91 was accepted';
  exception when others then
    if sqlerrm like '%out of range%' then
      raise notice 'PASS  an out-of-range coordinate is refused';
    else raise; end if;
  end;
end $$;

\echo ''
\echo '=== Switching the simulator off withdraws access again ==='

update trust_config set value = 0 where key = 'simulator_enabled';

do $$
begin
  begin
    perform sim_cities();
    raise exception 'FAIL  the simulator still works after being switched off';
  exception when others then
    if sqlerrm like '%disabled%' then
      raise notice 'PASS  switching the flag off withdraws access';
    else raise; end if;
  end;
end $$;
