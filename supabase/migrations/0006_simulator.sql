-- RevMap: the trust simulator.
--
-- Lets a demonstrator drive the trust model directly -- set a reviewer's scores,
-- post a review at a chosen evidence level, and watch the aggregate move --
-- without waiting for real behavioural history to accumulate.
--
-- This is a DEMONSTRATION INSTRUMENT, not a product feature. It is gated behind
-- a configuration flag that is OFF by default, because these functions bypass
-- the rules that make the real system trustworthy:
--
--   * they let a caller set user_trust and city_trust directly, which the real
--     flow derives from behaviour;
--   * they can post a review with a chosen review_trust rather than one earned
--     from visit evidence;
--   * they run as the table owner, so row-level security does not apply.
--
-- Turning the flag off is the whole revocation. Nothing else in the app calls
-- these, and no other code path can produce a forged weight.
--
-- Apply after 0001..0005. Safe to run more than once.

insert into trust_config (key, value) values
  ('simulator_enabled', 0)          -- set to 1 to enable, from the SQL editor
on conflict (key) do update set value = excluded.value;

comment on table trust_config is
  'All tunables for the trust system, including simulator_enabled. That flag '
  'gates every sim_* function; set it back to 0 to withdraw simulator access.';

-- Refuses unless the simulator has been switched on deliberately.
create or replace function sim_require_enabled()
returns void language plpgsql stable as $$
begin
  if coalesce(cfg('simulator_enabled'), 0) <> 1 then
    raise exception
      'The simulator is disabled. Set simulator_enabled = 1 in trust_config to use it.'
      using errcode = '42501';
  end if;
end $$;

-- =====================================================================
-- 1. Accounts
-- =====================================================================

-- Creates (or reuses) a demonstration account.
--
-- A real auth.users row is created so the profile and trust tables line up the
-- way they do in production; the password is not usable for signing in through
-- the app, because sign-in goes through GoTrue.
create or replace function sim_create_account(
  p_handle text,
  p_role   text default 'user',
  p_email  text default null
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_user uuid; v_email text;
begin
  perform sim_require_enabled();

  v_email := coalesce(p_email, p_handle || '-' || substr(gen_random_uuid()::text, 1, 8) || '@demo.local');

  -- Reuse the account if this handle already exists, so a demo can be repeated.
  select p.id into v_user from profiles p where p.handle = p_handle;
  if v_user is not null then
    return v_user;
  end if;

  -- The id is generated here rather than by a column default: on Supabase,
  -- auth.users.id has no default because GoTrue creates it in application
  -- code. Relying on a default works against a permissive local stub and fails
  -- against the real project with
  --   null value in column "id" of relation "users" violates not-null constraint
  insert into auth.users (id, aud, role, email)
  values (gen_random_uuid(), 'authenticated', 'authenticated', v_email)
  returning id into v_user;

  insert into profiles (id, handle, display_name, role)
  values (v_user, p_handle, p_handle, coalesce(p_role, 'user'));

  -- Trust starts where a genuine new account starts.
  insert into user_trust (user_id, user_trust, last_computed_at)
  values (v_user, 10, now());

  return v_user;
end $$;

-- Sets the three scores that decide how much a review counts.
--
-- city_trust is applied to the place's own city, which is the comparison the
-- weighting formula actually makes.
create or replace function sim_set_trust(
  p_user_id    uuid,
  p_place_id   uuid,
  p_user_trust numeric,
  p_city_trust numeric
) returns void
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_city uuid;
begin
  perform sim_require_enabled();

  update user_trust
     set user_trust = greatest(0, least(100, p_user_trust)),
         last_computed_at = now()
   where user_id = p_user_id;

  select city_id into v_city from places where id = p_place_id;
  if v_city is null then
    raise exception 'place not found' using errcode = 'P0002';
  end if;

  -- A row for this city is created on demand; a real account would accumulate
  -- one through ordinary activity.
  insert into user_city_trust (user_id, city_id, city_trust, first_seen_at)
  values (p_user_id, v_city, greatest(0, least(100, p_city_trust)), now())
  on conflict (user_id, city_id) do update
    set city_trust = excluded.city_trust, updated_at = now();
end $$;

-- =====================================================================
-- 2. Reviews
-- =====================================================================

-- Posts a review with an explicitly chosen review_trust.
--
-- The ordinary route computes review_trust from visit evidence; this overrides
-- it so a demonstrator can show the same reviewer producing a strongly and a
-- weakly evidenced review, which is the contrast the whole system rests on.
create or replace function sim_post_review(
  p_user_id     uuid,
  p_place_id    uuid,
  p_rating      integer,
  p_review_trust numeric,
  p_text        text default ''
) returns uuid
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user numeric; v_city numeric; v_weight numeric;
  v_city_id uuid; v_review_id uuid; v_user_id uuid;
begin
  perform sim_require_enabled();

  select ut.user_trust into v_user from user_trust ut where ut.user_id = p_user_id;
  v_user := coalesce(v_user, 10);

  select p.city_id into v_city_id from places p where p.id = p_place_id;
  if v_city_id is null then
    raise exception 'place not found' using errcode = 'P0002';
  end if;

  select uct.city_trust into v_city from user_city_trust uct
   where uct.user_id = p_user_id and uct.city_id = v_city_id;
  v_city := coalesce(v_city, 0);

  -- The real formula, untouched. The simulator does not invent weights; it only
  -- chooses the inputs.
  v_weight := calculate_review_weight(
    v_user, v_city, greatest(0, least(100, p_review_trust)));

  -- The BEFORE INSERT trigger on reviews stamps identity from auth.uid(), which
  -- is what stops a client from posting as somebody else. A direct SQL session
  -- has no JWT, so the claim is set here exactly as PostgREST sets it per
  -- request. The trigger then does the right thing without being weakened.
  perform set_config('request.jwt.claim.sub', p_user_id::text, false);

  -- A simulated review is written as the owner, so the one-review-per-person
  -- rule and RLS do not apply; a repeat replaces the earlier attempt.
  select r.id into v_review_id
    from reviews r where r.user_id = p_user_id and r.place_id = p_place_id;
  if v_review_id is not null then
    update reviews
       set rating = p_rating,
           text = coalesce(p_text, ''),
           review_trust = greatest(0, least(100, p_review_trust)),
           review_weight = v_weight,
           updated_at = now()
     where id = v_review_id;
    return v_review_id;
  end if;

  -- The row is inserted with only what a client may set. The BEFORE INSERT
  -- trigger then computes trust from genuine visit evidence and overwrites
  -- whatever was supplied -- which is correct, and is why the simulator cannot
  -- simply pass its own review_trust in.
  --
  -- So the simulated values are applied afterwards. The trigger is BEFORE
  -- INSERT only, so an update is not recomputed, and this stays a demonstration
  -- of the real formula rather than a way around it.
  insert into reviews (user_id, place_id, rating, text)
  values (p_user_id, p_place_id, greatest(1, least(5, p_rating)), coalesce(p_text, ''))
  returning id into v_review_id;

  update reviews
     set review_trust  = greatest(0, least(100, p_review_trust)),
         review_weight = v_weight,
         user_trust    = v_user,
         city_trust    = v_city,
         fraud_score   = 0,
         explanation   = explanation
                        || jsonb_build_object(
                             'user_trust', v_user,
                             'city_trust', v_city,
                             'review_trust', greatest(0, least(100, p_review_trust)),
                             'review_weight', v_weight,
                             'local_bonus_applied', v_city >= cfg('city_local_threshold'),
                             'source', 'simulator')
   where id = v_review_id;

  return v_review_id;
end $$;

-- =====================================================================
-- 3. Inspection and reset
-- =====================================================================

-- What a set of scores is worth, without writing anything. Used by the
-- simulator's live panel so dragging a slider is instant.
create or replace function sim_preview_weight(
  p_user_trust   numeric,
  p_city_trust   numeric,
  p_review_trust numeric
) returns numeric
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform sim_require_enabled();
  return calculate_review_weight(p_user_trust, p_city_trust, p_review_trust);
end $$;

-- The live aggregate for a place, so the demonstrator can show it moving.
create or replace function sim_place_summary(p_place_id uuid)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_rating record; v_reviews int;
begin
  perform sim_require_enabled();

  select * into v_rating from place_rating(p_place_id);
  select count(*) into v_reviews from reviews
    where place_id = p_place_id and status = 'published';

  return jsonb_build_object(
    'adjusted_rating',  v_rating.adjusted_rating,
    'effective_count',  v_rating.effective_review_count,
    'raw_count',        v_rating.raw_review_count,
    'review_rows',      v_reviews,
    'confidence',       place_confidence(p_place_id));
end $$;

-- Demonstration accounts, for the account picker.
create or replace function sim_list_accounts()
returns table (user_id uuid, handle text, role text, user_trust numeric)
language sql security definer set search_path = public, extensions as $$
  -- Scoped to demonstration accounts so a real user's row can never appear in
  -- the simulator's picker.
  select p.id, p.handle, p.role, coalesce(ut.user_trust, 10)
  from profiles p
  join auth.users u on u.id = p.id
  left join user_trust ut on ut.user_id = p.id
  where u.email like '%@demo.local'
  order by p.created_at desc
  limit 50;
$$;

-- Clears simulated reviews and scores, returning the database to its seeded
-- state. Scoped to rows the simulator created, so it cannot delete a real
-- account's history by accident.
create or replace function sim_reset()
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform sim_require_enabled();

  delete from reviews
   where explanation->>'source' = 'simulator';

  -- Reset the scores of demonstration accounts. They are identified by the
  -- @demo.local address on the auth record, not by a column on profiles,
  -- which has no email.
  update user_trust
     set user_trust = 10, last_computed_at = now()
   where user_id in (
     select u.id from auth.users u where u.email like '%@demo.local');
end $$;

-- =====================================================================
-- Access
-- =====================================================================
-- Granted to authenticated, but every function above re-checks the
-- simulator_enabled flag, so withdrawing access is a one-row update rather
-- than a hunt through grants.

grant execute on function sim_create_account(text, text, text)          to authenticated;
grant execute on function sim_set_trust(uuid, uuid, numeric, numeric)   to authenticated;
grant execute on function sim_post_review(uuid, uuid, integer, numeric, text) to authenticated;
grant execute on function sim_preview_weight(numeric, numeric, numeric) to authenticated;
grant execute on function sim_place_summary(uuid)                     to authenticated;
grant execute on function sim_list_accounts()                          to authenticated;
grant execute on function sim_reset()                                  to authenticated;

revoke execute on all functions in schema public from anon;
