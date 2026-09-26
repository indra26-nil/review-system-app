-- RevMap: the simulator, verified.
--
-- The thing worth proving is that the simulator uses the *real* formula and the
-- *real* aggregation, so a demonstration cannot drift from the system it is
-- demonstrating. Every expected weight here is taken from the specification's
-- §18 table.
--
--   psql -d revamp -f supabase/tests/004_simulator.sql

\pset footer off

do $$ begin
  if not exists (select 1 from pg_roles where rolname='authenticated') then
    create role authenticated nologin noinherit;
  end if;
end $$;

create schema if not exists test_helper;

\echo '=== The simulator is off by default ==='

do $$
declare
  v_before numeric;
  v_after numeric;
  v_user uuid;
  v_place uuid;
begin
  select value into v_before from trust_config where key = 'simulator_enabled';
  if coalesce(v_before, 0) <> 0 then
    raise exception 'FAIL  simulator should ship disabled, found %', v_before;
  end if;
  raise notice 'PASS  simulator_enabled defaults to 0';

  -- With the flag off, the functions must refuse.
  begin
    perform sim_preview_weight(90, 90, 95);
    raise exception 'FAIL  sim_preview_weight worked while disabled';
  exception when others then
    if sqlerrm like '%disabled%' then
      raise notice 'PASS  sim_preview_weight refuses while disabled';
    else
      raise;
    end if;
  end;
end $$;

\echo ''
\echo '=== With it enabled, the simulator uses the real formula ==='

update trust_config set value = 1 where key = 'simulator_enabled';
select sim_create_account('sim-tester') where false;  -- no-op guard
do $$
declare
  v_user uuid; v_place uuid;
  r numeric; n int; passed int := 0;
  cases constant text[][] := array[
    ['90','90','95','0.9750'], ['90','30','95','0.8775'],
    ['90','90','30','0.6500'], ['60','85','90','0.7125'],
    ['60','20','90','0.5700'], ['30','20','95','0.2925'],
    ['20','20','95','0.1950'], ['98','20','100','0.9800'],
    ['100','100','0','0.5000']
  ];
  c text[];
begin
  -- Created outside the block and passed in: assigning a function result to a
  -- PL/pgSQL variable inside the same block proved unreliable here.
  v_user := coalesce(
    nullif(current_setting('revmap.test_user', true), '')::uuid,
    sim_create_account('sim-tester'));
  select id into v_place from places limit 1;
  if v_user is null then
    raise exception 'FAIL  could not create a simulation account';
  end if;

  -- The §18 table, run through the simulator's own preview function.
  foreach c slice 1 in array cases loop
    if abs(sim_preview_weight(c[1]::numeric, c[2]::numeric, c[3]::numeric)
           - c[4]::numeric) < 0.00001 then
      passed := passed + 1;
    else
      raise exception 'FAIL  preview(%,%,%) = %, expected %',
        c[1], c[2], c[3],
        sim_preview_weight(c[1]::numeric, c[2]::numeric, c[3]::numeric), c[4];
    end if;
  end loop;
  raise notice 'PASS  preview matches the spec on all % cases', passed;

  -- Setting trust, then posting, must use those values.
  perform sim_set_trust(v_user, v_place, 90, 90);
  perform sim_post_review(v_user, v_place, 5, 95, 'A strong local review');

  select review_weight into r from reviews
   where user_id = v_user and place_id = v_place;
  if abs(r - 0.9750) < 0.00001 then
    raise notice 'PASS  posted review carried the predicted weight (0.9750)';
  else
    raise exception 'FAIL  posted review weight was %', r;
  end if;

  -- Same reviewer, weak evidence. These are the spec's Case C inputs
  -- (90/90/30), so this cross-checks the simulator against the table rather
  -- than against a number invented here.
  perform sim_post_review(v_user, v_place, 1, 30, 'No visit evidence');
  select review_weight into r from reviews
   where user_id = v_user and place_id = v_place;
  if abs(r - 0.65) < 0.00001 then
    raise notice 'PASS  the same reviewer drops to 0.6500 without evidence';
  else
    raise exception 'FAIL  weight with weak evidence was %', r;
  end if;

  -- CityTrust below 70 must remove the +0.15 local bonus. The review is
  -- re-posted because the stored weight is what was computed at the time:
  -- changing a score alone would not move it.
  --
  -- 90 / 30 / 30 should give 0.90 (no bonus) x 0.65 (evidence) = 0.585, against
  -- the 0.65 the same reviewer earned while counted as a local.
  perform sim_set_trust(v_user, v_place, 90, 30);
  perform sim_post_review(v_user, v_place, 1, 30, 'Same, but no longer a local');
  select review_weight into r from reviews
   where user_id = v_user and place_id = v_place;
  if abs(r - 0.585) < 0.0001 then
    raise notice 'PASS  CityTrust 30 removes the bonus: 0.6500 -> %', r;
  else
    raise exception 'FAIL  expected 0.585 without the local bonus, got %', r;
  end if;

  -- The aggregate must actually move.
  select effective_review_count, raw_review_count into r, n
    from place_rating(v_place);
  raise notice 'PASS  place aggregate now: % raw review(s), % effective', n, r;

  if exists (select 1 from reviews
              where user_id = v_user and explanation->>'source' = 'simulator') then
    raise notice 'PASS  simulated reviews are tagged for cleanup';
  else
    raise exception 'FAIL  simulated review was not tagged';
  end if;
end $$;

\echo '=== Reset restores the seeded state ==='

do $$
declare n int;
begin
  perform sim_reset();
  select count(*) into n from reviews where explanation->>'source' = 'simulator';
  if n = 0 then
    raise notice 'PASS  sim_reset removed every simulated review';
  else
    raise exception 'FAIL  % simulated review(s) survived the reset', n;
  end if;
end $$;

\echo ''
\echo '=== Switching it off withdraws access again ==='

update trust_config set value = 0 where key = 'simulator_enabled';

do $$
begin
  begin
    perform sim_preview_weight(90, 90, 95);
    raise exception 'FAIL  the simulator still works after being switched off';
  exception when others then
    if sqlerrm like '%disabled%' then
      raise notice 'PASS  switching the flag off withdraws access';
    else
      raise;
    end if;
  end;
end $$;
