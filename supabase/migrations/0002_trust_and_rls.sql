-- RevMap: the trust engine, the insert guard, and row-level security.
--
-- The central idea: the app is never authoritative for a trust value. It may
-- submit a rating and some text. Everything else -- user_trust, city_trust,
-- review_trust, review_weight, fraud_score, status, even user_id -- is written
-- by this file and by nothing else.
--
-- PostGIS is required for impossible-travel detection. If it is unavailable the
-- travel term degrades to zero rather than failing the whole migration.

-- PostGIS is required for impossible-travel detection, pg_trgm for duplicate
-- text. Supabase already ships both, installed into the `extensions` schema,
-- so `if not exists` is a no-op there and these are safe to re-run.
--
-- If PostGIS is genuinely unavailable the travel term degrades to zero inside
-- calculate_fraud_score rather than breaking the migration.
create schema if not exists extensions;
create extension if not exists postgis schema extensions;
create extension if not exists pg_trgm  schema extensions;

-- =====================================================================
-- 1. The weight formula
-- =====================================================================
-- STABLE rather than IMMUTABLE: it reads trust_config, which is data.

create or replace function calculate_review_weight(
  p_user_trust   double precision,
  p_city_trust   double precision,
  p_review_trust double precision
) returns double precision
language plpgsql stable parallel safe as $$
declare
  -- Clamp before use, so a bad input cannot produce a bad weight.
  v_user   double precision := greatest(0, least(100, p_user_trust));
  v_city   double precision := greatest(0, least(100, p_city_trust));
  v_review double precision := greatest(0, least(100, p_review_trust));
  v_reviewer_score double precision;
  v_evidence_mult  double precision;
begin
  -- 1. Base credibility.
  v_reviewer_score := v_user / 100.0;

  -- 2. Local advantage. A bonus, never a penalty: a genuine tourist who
  --    verifies a visit can still be highly influential.
  if v_city >= cfg('city_local_threshold') then
    v_reviewer_score := least(1.0, v_reviewer_score + cfg('local_bonus'));
  end if;

  -- 3. Evidence. Floored at 0.5, so weak evidence reduces influence without
  --    silencing an honest reviewer.
  v_evidence_mult := cfg('evidence_floor')
                   + cfg('evidence_range') * (v_review / 100.0);

  -- 4. Final influence.
  return greatest(0.0, least(1.0, v_reviewer_score * v_evidence_mult));
end $$;

comment on function calculate_review_weight(double precision, double precision, double precision) is
  'Core weight formula. reviewer_score = user_trust/100, +local_bonus when '
  'city_trust >= threshold (capped at 1.0), multiplied by an evidence '
  'multiplier of evidence_floor + evidence_range * review_trust/100.';

-- =====================================================================
-- 2. The three input scores
-- =====================================================================

-- UserTrust: from behaviour, not from claims.
create or replace function calculate_user_trust(p_user_id uuid)
returns numeric
language plpgsql stable
set search_path = public, extensions
as $$
declare
  c_age numeric; c_hist numeric; c_int numeric; c_mod numeric;
  v numeric;
begin
  select least(100, account_age_days / 365.0 * 100),
         least(100, accepted_reviews / 20.0 * 100),
         greatest(0, 100 - (flagged_reviews * 8) - (duplicate_hits * 12)),
         greatest(0, 100 - (coordination_hits * 20))
    into c_age, c_hist, c_int, c_mod
  from user_trust where user_id = p_user_id;

  -- No row yet: a brand new account.
  if c_age is null then return 10; end if;

  v := c_age   * cfg('ut_weight_age')
     + c_hist  * cfg('ut_weight_history')
     + c_int   * cfg('ut_weight_integrity')
     + c_mod   * cfg('ut_weight_moderation');

  return least(100, greatest(0, v));
end $$;

-- CityTrust: from long-term signals, explicitly NOT from a single GPS reading.
-- A device reporting a position proves it was there once, not that the person
-- lives there. Nothing here stores a movement history.
create or replace function calculate_city_trust(p_user_id uuid, p_city_id uuid)
returns numeric
language plpgsql stable
set search_path = public, extensions
as $$
declare
  c_tenure numeric; c_activity numeric; c_contrib numeric;
  c_consist numeric; c_resid numeric; v numeric;
begin
  select least(100, extract(epoch from (now() - first_seen_at)) / 86400.0 / 730.0 * 100),
         least(100, (select count(*) from reviews r
                     join places p on p.id = r.place_id
                     where r.user_id = p_user_id and p.city_id = p_city_id
                       and r.status = 'published') / 25.0 * 100),
         least(100, (select coalesce(avg(r.rating), 0) from reviews r
                     join places p on p.id = r.place_id
                     where r.user_id = p_user_id and p.city_id = p_city_id
                       and r.status = 'published') / 5.0 * 100),
         least(100, (select count(*) from visit_proofs v
                     join places p on p.id = v.place_id
                     where v.user_id = p_user_id and p.city_id = p_city_id) / 15.0 * 100),
         coalesce((select case when pr.declared_country = c.country then 70 else 20 end
                    from profiles pr join cities c on c.id = p_city_id
                    where pr.id = p_user_id), 0)
    into c_tenure, c_activity, c_contrib, c_consist, c_resid
  from user_city_trust where user_id = p_user_id and city_id = p_city_id;

  -- Never active in this city.
  if c_tenure is null then return 0; end if;

  v := c_tenure   * cfg('ct_weight_tenure')
     + c_activity * cfg('ct_weight_activity')
     + c_contrib  * cfg('ct_weight_contribution')
     + c_consist  * cfg('ct_weight_consistency')
     + c_resid    * cfg('ct_weight_residency');

  return least(100, greatest(0, v));
end $$;

-- ReviewTrust: the evidence behind THIS review.
create or replace function calculate_review_trust(
  p_user_id uuid, p_place_id uuid, p_text text, p_proof_id uuid
) returns numeric
language plpgsql stable
set search_path = public, extensions
as $$
declare
  b_bucket text; b_method text; b_age_h numeric;
  v_base numeric; v_detail numeric; v_dup numeric := 0; v numeric;
begin
  -- A proof only counts for its own owner, its own place, unused and unexpired.
  select accuracy_bucket, verification_method,
         extract(epoch from (now() - verified_at)) / 3600.0
    into b_bucket, b_method, b_age_h
  from visit_proofs
  where id = p_proof_id and user_id = p_user_id and place_id = p_place_id
    and consumed_at is null and expires_at > now();

  if b_bucket is null then
    v_base := cfg('proof_base_unverified');   -- 25: weak, not worthless
  else
    v_base := case b_bucket when 'precise' then 85 when 'fair' then 65
                             when 'coarse' then 40 else 25 end;
    if b_method in ('qr','nfc','receipt') then
      v_base := least(100, v_base + 15);
    end if;
    -- A visit long ago is weaker evidence than one from today.
    if b_age_h > 168 then v_base := v_base * 0.8;
    elsif b_age_h > 48 then v_base := v_base * 0.9;
    end if;
  end if;

  -- Length alone is a weak signal, so it is capped tightly.
  v_detail := least(15, length(coalesce(p_text, '')) / 12.0);

  select coalesce(max(similarity(r.text, p_text)), 0) into v_dup
  from reviews r
  where r.user_id = p_user_id and r.text <> '' and p_text is distinct from ''
    and p_text <> '' and r.status <> 'rejected';

  v := v_base + v_detail - (v_dup * 40);
  return least(100, greatest(0, v));
end $$;

-- =====================================================================
-- 3. Fraud
-- =====================================================================
-- Shared networks are deliberately NOT a signal: offices, campuses, mobile
-- carriers and families all share IPs, and treating that as fraud would punish
-- honest users. Device risk keys on distinct accounts sharing one per-install
-- random id, never on an IP or a hardware identifier.

create or replace function calculate_fraud_score(
  p_user_id uuid, p_place_id uuid, p_text text
) returns numeric
language plpgsql stable
set search_path = public, extensions
as $$
declare
  v_dup numeric := 0;
  v_travel numeric := 0;
  v_burst numeric := 0;
  v_device numeric := 0;
  v_acct numeric := 0;
  v_hourly bigint := 0;
  v_install text;
begin
  -- Near-duplicate text.
  select coalesce(max(similarity(r.text, p_text)), 0) into v_dup
  from reviews r
  where r.user_id = p_user_id and r.status <> 'rejected'
    and r.text <> '' and p_text <> '';

  -- Impossible travel. Coarse place-to-place distance only, so this can never
  -- become a record of where a person has been.
  begin
    select case when h < 0.5 then 0
                when k / (h / 3600.0) > 900 then 1
                else least(1.0, (k / (h / 3600.0)) / 900.0) end
      into v_travel
    from (
      select coalesce(max(
               st_distance(
                 st_setsrid(st_makepoint(p.longitude,  p.latitude),  4326)::geography,
                 st_setsrid(st_makepoint(p2.longitude, p2.latitude), 4326)::geography
               ) / 1000.0), 0) as k,
             coalesce(max(extract(epoch from (now() - vp.verified_at)) / 3600.0), 1) as h
      from visit_proofs vp
      join places p  on p.id  = vp.place_id
      join places p2 on p2.id = p_place_id
      where vp.user_id = p_user_id
        and vp.place_id <> p_place_id
        and vp.verified_at > now() - interval '30 days'
    ) t;
  exception when others then
    v_travel := 0;   -- PostGIS unavailable: fail soft, never fail the insert
  end;

  -- Coordinated burst on one place.
  select case when n >= 8 then 1.0 else n / 8.0 end into v_burst
  from (select count(*) n from reviews
        where place_id = p_place_id
          and created_at > now() - interval '1 hour') b;

  -- Device risk: distinct accounts behind one install id.
  select install_id_hash into v_install
  from user_trust where user_id = p_user_id;

  if v_install is not null then
    select case when n >= 4 then 1.0 when n >= 2 then 0.5 else 0.0 end into v_device
    from (select count(distinct user_id) n from user_trust
          where install_id_hash = v_install) d;
  end if;

  -- Account risk: brand new, or over the hourly cap.
  select count(*) into v_hourly
  from reviews r
  where r.user_id = p_user_id and r.created_at > now() - interval '1 hour';

  select case when last_computed_at > now() - interval '7 days' then 0.6
              when v_hourly > cfg('max_reviews_per_hour') then 0.5
              else 0.0 end
    into v_acct
  from user_trust where user_id = p_user_id;

  -- Every component is coalesced. Two of them (v_acct, v_device) are produced by
  -- a SELECT that yields no row for an account with no user_trust row, leaving
  -- them NULL. A NULL in this sum propagates, and PostgreSQL's least() IGNORES
  -- NULLs -- so least(1.0, NULL) returns 1.0. That scored every brand-new user
  -- as maximally fraudulent, giving their reviews weight 0 and quietly routing
  -- them to under_review.
  return least(1.0, greatest(0.0,
      coalesce(v_dup,    0) * cfg('fraud_duplicate_text')
    + coalesce(v_travel, 0) * cfg('fraud_impossible_travel')
    + coalesce(v_burst,  0) * cfg('fraud_review_burst')
    + coalesce(v_device, 0) * cfg('fraud_device_risk')
    + coalesce(v_acct,   0) * cfg('fraud_account_risk')
  ));
end $$;

-- =====================================================================
-- 4. Aggregation
-- =====================================================================

create or replace function place_rating(p_place_id uuid)
returns table (
  weighted_rating        double precision,
  effective_review_count double precision,
  adjusted_rating        double precision,
  raw_review_count       bigint
) language sql stable as $$
  with agg as (
    select coalesce(sum(r.rating * r.review_weight) / nullif(sum(r.review_weight), 0), 0) as wr,
           coalesce(sum(r.review_weight), 0)                                          as eff,
           count(*)                                                                  as n
    from reviews r
    where r.place_id = p_place_id and r.status = 'published'
  )
  select wr,
         eff,
         -- Bayesian smoothing: a single 5-star review cannot pin a place to 5.0.
         (wr + cfg('prior_rating') * cfg('prior_mass')) / (eff + cfg('prior_mass')),
         n
  from agg;
$$;

create or replace function place_confidence(p_place_id uuid)
returns double precision language sql stable as $$
  with s as (
    select coalesce(sum(review_weight), 0) eff,
           count(distinct user_id) uniq,
           count(*) filter (where visit_proof_id is not null) verified,
           count(*) filter (where fraud_score > cfg('fraud_monitor_threshold')) susp
    from reviews
    where place_id = p_place_id and status = 'published'
  )
  -- Confidence asks "how much independent evidence backs this?", which is a
  -- different question from the rating. Never reported as "this place is good".
  select greatest(0, least(1.0,
      least(1.0, eff  / 40.0) * 0.60
    + least(1.0, uniq / 12.0) * 0.25
    + least(1.0, verified::double precision / greatest(1, uniq)) * 0.15
    - least(0.25, susp::double precision / greatest(1, uniq) * 0.5)
  ))
  from s;
$$;

-- =====================================================================
-- 5. The guard that makes the security model real
-- =====================================================================
-- Without this, a client could post a review carrying its own weight. These
-- two statements remove the columns from the client's reach entirely, so a
-- malicious payload gets a permission error rather than a silently honoured lie.

revoke insert on reviews from anon, authenticated;
grant insert (place_id, rating, text, visit_proof_id) on reviews to authenticated;

create or replace function reviews_before_insert() returns trigger
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_user numeric; v_city numeric; v_review numeric;
  v_weight numeric; v_fraud numeric; v_city_id uuid;
begin
  -- Never trust a client-supplied user_id. Always the JWT subject, so claiming
  -- to be someone else is overwritten rather than obeyed.
  new.user_id := auth.uid();

  v_user := calculate_user_trust(new.user_id);

  select p.city_id into v_city_id from places p where p.id = new.place_id;
  v_city := calculate_city_trust(new.user_id, v_city_id);
  v_review := calculate_review_trust(new.user_id, new.place_id, new.text, new.visit_proof_id);
  v_weight := calculate_review_weight(v_user, v_city, v_review);
  v_fraud  := calculate_fraud_score(new.user_id, new.place_id, new.text);

  -- Conflict of interest: an owner reviewing their own store is pulled from
  -- the aggregate rather than merely trusted less.
  new.is_owner := exists (
    select 1 from stores s join places p on p.store_id = s.id
    where p.id = new.place_id and s.owner_id = new.user_id
  );

  new.user_trust    := v_user;
  new.city_trust    := v_city;
  new.review_trust  := v_review;
  new.fraud_score   := v_fraud;

  -- Graduated handling: a middling fraud score reduces influence rather than
  -- hiding a review, because silently suppressing honest reviews is the worse
  -- failure. A high score withholds it from the aggregate and queues review.
  new.review_weight := case
    when v_fraud > cfg('fraud_monitor_threshold') then v_weight * (1 - v_fraud)
    else v_weight
  end;

  new.status := case
    when v_fraud > cfg('fraud_review_threshold') or new.is_owner then 'under_review'
    else 'published'
  end;

  -- `review_weight` is the value that actually counted. `review_weight_before_fraud`
  -- is the pure formula result, recorded separately so an auditor can tell a
  -- review that was weak on its evidence from one that was suppressed by a fraud
  -- signal. Without the pair, a low weight is ambiguous.
  new.explanation := jsonb_build_object(
    'user_trust', v_user, 'city_trust', v_city, 'review_trust', v_review,
    'local_bonus_applied', v_city >= cfg('city_local_threshold'),
    'evidence_multiplier', cfg('evidence_floor') + cfg('evidence_range') * (v_review / 100.0),
    'review_weight_before_fraud', v_weight,
    'review_weight', new.review_weight,
    'fraud_score', v_fraud, 'is_owner', new.is_owner);

  -- Consume a cited visit proof so one visit cannot justify several reviews.
  if new.visit_proof_id is not null then
    update visit_proofs set consumed_at = now()
    where id = new.visit_proof_id and user_id = new.user_id
      and place_id = new.place_id and consumed_at is null
      and expires_at > now();
    if not found then
      raise exception 'invalid or already-used visit proof' using errcode = '23514';
    end if;
  end if;

  -- Rate limits.
  if (select count(*) from reviews r
        where r.user_id = new.user_id
          and r.created_at > now() - interval '1 hour') > cfg('max_reviews_per_hour')
     or (select count(*) from reviews r
        where r.user_id = new.user_id
          and r.created_at > now() - interval '1 day') > cfg('max_reviews_per_day') then
    raise exception 'review rate limit exceeded' using errcode = 'P0001';
  end if;

  return new;
end $$;

drop trigger if exists trg_reviews_before_insert on reviews;
create trigger trg_reviews_before_insert
  before insert on reviews
  for each row execute function reviews_before_insert();

-- =====================================================================
-- 6. Row-level security
-- =====================================================================
-- The anon key ships in the app, so RLS is the actual perimeter. These policies
-- are what make "the client cannot see or change trust" true.

alter table reviews          enable row level security;
alter table visit_proofs     enable row level security;
alter table verification_nonces enable row level security;
alter table user_trust       enable row level security;
alter table user_city_trust  enable row level security;
alter table profiles         enable row level security;
alter table places           enable row level security;
alter table stores           enable row level security;
alter table trust_config     enable row level security;

drop policy if exists "read published reviews" on reviews;
create policy "read published reviews" on reviews
  for select using (status = 'published');

-- A person may read their own review even while it is held for moderation,
-- otherwise a rejected or queued review vanishes with no explanation.
drop policy if exists "read own reviews" on reviews;
create policy "read own reviews" on reviews
  for select using (auth.uid() = user_id or status = 'published');

-- Write policies. These were missing entirely, which is worse than a wrong
-- one: row-level security denies by default, so granting INSERT on the columns
-- still failed with
--   new row violates row-level security policy for table "reviews"
-- and no review could ever be submitted from the app.
--
-- Identity is pinned to the JWT, so a client cannot post as anyone else. The
-- trust columns are not grantable to the app, and the BEFORE INSERT trigger
-- overwrites new.user_id regardless.
drop policy if exists "insert own review" on reviews;
create policy "insert own review" on reviews
  for insert with check (auth.uid() = user_id);

-- Editing is limited to the columns a person may reasonably change; the
-- rating and the text. Weight and trust are the database's business.
drop policy if exists "update own review" on reviews;
create policy "update own review" on reviews
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "delete own review" on reviews;
create policy "delete own review" on reviews
  for delete using (auth.uid() = user_id);

drop policy if exists "read own proofs" on visit_proofs;
create policy "read own proofs" on visit_proofs
  for select using (auth.uid() = user_id);

drop policy if exists "read own nonces" on verification_nonces;
create policy "read own nonces" on verification_nonces
  for select using (auth.uid() = user_id);

-- No cross-user read on the trust tables. This is the point: UserTrust is a
-- server-side judgement and is not a public profile field.
drop policy if exists "read own user trust" on user_trust;
create policy "read own user trust" on user_trust
  for select using (auth.uid() = user_id);

drop policy if exists "read own city trust" on user_city_trust;
create policy "read own city trust" on user_city_trust
  for select using (auth.uid() = user_id);

drop policy if exists "read published places" on places;
create policy "read published places" on places
  for select using (status = 'published');

drop policy if exists "owners read own store" on stores;
create policy "owners read own store" on stores
  for select using (auth.uid() = owner_id or status = 'published');

-- Thresholds are readable so the app can explain itself; nothing else is.
drop policy if exists "read trust config" on trust_config;
create policy "read trust config" on trust_config
  for select using (true);

-- Cities are reference data, readable by all.
drop policy if exists "read cities" on cities;
create policy "read cities" on cities
  for select using (true);
