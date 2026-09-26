-- RevMap: the security guarantees, verified.
--
-- The claim under test is not "we compute trust server-side" but "a client
-- CANNOT set a trust value or an identity, even if it tries". That is a
-- property of grants and triggers, so it is tested as one.
--
-- PostgREST sets `request.jwt.claim.sub` per request; auth.uid() reads it.
-- The tests below set that claim the same way, so the trigger sees a real
-- subject the way it would in production.
--
--   psql -d revamp -f supabase/tests/002_security.sql

\pset footer off

-- Supabase creates these roles; has_column_privilege() needs them to exist.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit; end if;
end $$;

\echo '=== A client cannot write trust columns or choose its own identity ==='

do $$
declare
  v_place uuid;
  v_user  uuid;
  v_row   reviews;
  v_err   text;
begin
  select id into v_place from places limit 1;

  insert into auth.users (email) values ('author-' || gen_random_uuid() || '@example.com')
    returning id into v_user;
  -- user_trust references profiles, which references auth.users: a trust row
  -- legitimately requires a profile to exist first.
  insert into profiles (id, handle) values (v_user, 'author-' || substr(v_user::text, 1, 8));

  ------------------------------------------------------------------
  -- 1. Column-level grants are the boundary.
  ------------------------------------------------------------------
  if has_column_privilege('authenticated', 'reviews', 'review_weight', 'INSERT') then
    raise exception 'FAIL  authenticated can insert review_weight';
  else
    raise notice 'PASS  authenticated cannot insert review_weight';
  end if;

  if has_column_privilege('authenticated', 'reviews', 'user_trust', 'INSERT') then
    raise exception 'FAIL  authenticated can insert user_trust';
  else
    raise notice 'PASS  authenticated cannot insert user_trust';
  end if;

  -- has_table_privilege(role, table, privilege) is the form that takes a
  -- role. The 3-argument has_column_privilege(table, column, privilege) would
  -- look for a *table* named 'anon'.
  if has_table_privilege('anon', 'reviews', 'INSERT') then
    raise notice 'NOTE  anon holds INSERT on reviews (supabase grants this by default)';
  else
    raise notice 'PASS  anon has no INSERT on reviews';
  end if;

  ------------------------------------------------------------------
  -- 2. Identity comes from the JWT, never from the request body.
  ------------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_user::text, false);

  -- The review is written by a superuser here, so it is *allowed* to name any
  -- user_id and any weight. The point is that the trigger overwrites both.
  insert into reviews (user_id, place_id, rating, text, review_weight, user_trust)
  values (gen_random_uuid(), v_place, 5, 'spoofed', 1.0, 100)
  returning * into v_row;

  if v_row.user_id <> v_user then
    raise exception 'FAIL  user_id was not taken from the JWT subject';
  else
    raise notice 'PASS  user_id overwritten with the JWT subject, ignoring the value supplied';
  end if;

  if v_row.review_weight = 1.0 then
    raise exception 'FAIL  a supplied review_weight of 1.0 was accepted';
  else
    raise notice 'PASS  supplied review_weight overwritten with %', v_row.review_weight;
  end if;

  if v_row.user_trust = 100 then
    raise exception 'FAIL  a supplied user_trust of 100 was accepted';
  else
    raise notice 'PASS  supplied user_trust overwritten with % (new accounts start low)', v_row.user_trust;
  end if;

  if v_row.explanation is not null then
    raise notice 'PASS  explanation recorded: weight=% review=% evidence=% local_bonus=%',
      v_row.explanation->>'review_weight',
      v_row.explanation->>'review_trust',
      v_row.explanation->>'evidence_multiplier',
      v_row.explanation->>'local_bonus_applied';
  else
    raise exception 'FAIL  no explanation recorded for audit';
  end if;

  -- The pre-fraud weight must equal the formula applied to the stored scores.
  -- The value that actually counted is then that, reduced by the fraud band
  -- (spec §28) when a fraud signal fired -- so both halves are checked, and a
  -- suppressed review stays distinguishable from a weakly-evidenced one.
  declare
    v_expected numeric := calculate_review_weight(
      v_row.user_trust, v_row.city_trust, v_row.review_trust);
    v_pre numeric;
    v_fraud numeric;
  begin
    v_pre := (v_row.explanation->>'review_weight_before_fraud')::numeric;
    v_fraud := coalesce((v_row.explanation->>'fraud_score')::numeric, 0);

    if abs(v_pre - v_expected) > 0.00001 then
      raise exception 'FAIL  pre-fraud weight % does not match the formula %', v_pre, v_expected;
    else
      raise notice 'PASS  pre-fraud weight matches the formula (% vs %)', v_pre, v_expected;
    end if;

    if v_fraud > cfg('fraud_monitor_threshold') then
      if abs(v_row.review_weight - (v_pre * (1 - v_fraud))) > 0.00001 then
        raise exception 'FAIL  fraud band not applied correctly';
      else
        raise notice 'PASS  fraud band applied: % x (1 - %s) = %',
          v_pre, v_fraud, v_row.review_weight;
      end if;
    else
      if abs(v_row.review_weight - v_pre) > 0.00001 then
        raise exception 'FAIL  weight altered despite no fraud signal';
      else
        raise notice 'PASS  no fraud signal, weight passed through unchanged';
      end if;
    end if;
  end;

  ------------------------------------------------------------------
  -- 3. Without a JWT there is no subject, so there is no review.
  ------------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', '', false);
  begin
    insert into reviews (user_id, place_id, rating, text) values (v_user, v_place, 3, 'no identity');
  exception when others then
    v_err := left(sqlerrm, 40);
  end;
  if v_err is not null then
    raise notice 'PASS  an unauthenticated insert is refused: %', v_err;
  else
    raise exception 'FAIL  an insert with no JWT subject was allowed';
  end if;

  ------------------------------------------------------------------
  -- 4. One review per person per place (spec §30).
  ------------------------------------------------------------------
  perform set_config('request.jwt.claim.sub', v_user::text, false);
  begin
    insert into reviews (user_id, place_id, rating, text) values (v_user, v_place, 1, 'second');
  exception when unique_violation then
    v_err := 'unique_violation';
  end;
  if v_err = 'unique_violation' then
    raise notice 'PASS  a second review from the same person was refused';
  else
    raise exception 'FAIL  duplicate review was allowed';
  end if;
end $$;

\echo ''
\echo '=== Row-level security: nobody reads another person''s trust ==='

do $$
declare
  v_a uuid; v_b uuid;
begin
  insert into auth.users (email) values ('a-' || gen_random_uuid() || '@example.com') returning id into v_a;
  insert into auth.users (email) values ('b-' || gen_random_uuid() || '@example.com') returning id into v_b;
  insert into profiles (id, handle)
  values (v_a, 'user-a-' || substr(v_a::text, 1, 8)), (v_b, 'user-b-' || substr(v_b::text, 1, 8));
  insert into user_trust (user_id, user_trust) values (v_a, 88), (v_b, 12);

  -- The policies themselves are asserted by inspection, because this session
  -- is a superuser and the table owner, both of which bypass RLS. A
  -- superuser "cannot read another user's trust" test would be vacuous: it
  -- could read everything regardless of the policies. What is checked here is
  -- that the policies exist and point the right way.
  if not exists (
    select 1 from pg_policies
    where tablename = 'user_trust' and policyname = 'read own user trust'
  ) then
    raise exception 'FAIL  the own-trust read policy is missing';
  else
    raise notice 'PASS  user_trust has an own-user read policy';
  end if;

  if not exists (
    select 1 from pg_policies
    where tablename = 'reviews' and policyname = 'read published reviews'
  ) then
    raise exception 'FAIL  the published-reviews read policy is missing';
  else
    raise notice 'PASS  reviews has a published-only read policy';
  end if;

  raise notice 'NOTE  policy enforcement itself is verified against the live '
              'project with a real anon key, not here (a superuser bypasses RLS).';
end $$;
