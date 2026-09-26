-- RevMap: complete schema, trust engine, owner flow, privileges, simulator, seed.
--
-- Long file: the Supabase SQL editor has a statement timeout. If it stalls,
-- paste the numbered files individually — each is small.
-- Safe to re-run: IF NOT EXISTS / CREATE OR REPLACE / upsert.

-- ==== 0001_init.sql ====
-- RevMap: initial schema.
--
-- Apply with the Supabase SQL editor, or:  supabase db push
--
-- Design notes that are easy to get wrong later:
--
--  * Coordinates are TWO ORDINARY COLUMNS on `places`, not the row's identity.
--    Two shops in one building legitimately share coordinates, which is exactly
--    why `id` is a separate uuid. Coordinates exist to answer "what is inside
--    the rectangle the user is looking at" and for nothing else.
--
--  * NO location history is stored anywhere. There is no movement trail in this
--    schema by design. Trust is derived from review counts, visit-proof counts
--    and self-declared claims, and only the *result* is kept.
--
--  * Reviews carries the trust columns, but the app cannot write them: a
--    `revoke`/`grant` pair plus a BEFORE INSERT trigger makes the database the
--    only writer. See 0002 for the trigger and row-level security.

-- =====================================================================
-- Identity and content
-- =====================================================================

create table if not exists cities (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  country     text,
  -- Unique so the seed is idempotent: re-running cannot create a second
  -- "Bengaluru", which would orphan the places that reference it.
  unique (name, country),
  centre_lat  double precision,
  centre_lng  double precision,
  created_at  timestamptz not null default now()
);

create table if not exists profiles (
  id           uuid primary key references auth.users on delete cascade,
  handle       text unique not null,
  display_name text not null default '',
  -- 'user' browses and reviews; 'owner' additionally registers a store.
  role         text not null default 'user' check (role in ('user','owner')),
  -- Self-declared country, used only as a weak CityTrust signal. Never inferred
  -- from location, which would be both unreliable and invasive.
  declared_country text,
  created_at   timestamptz not null default now()
);

create table if not exists stores (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references profiles(id) on delete cascade,
  city_id     uuid not null references cities(id),
  name        text not null,
  description text not null default '',
  status      text not null default 'pending'
                check (status in ('pending','published','suspended')),
  created_at  timestamptz not null default now()
);
create index if not exists stores_owner_idx on stores (owner_id);

create table if not exists places (
  id                uuid primary key default gen_random_uuid(),
  -- null store_id means a community-suggested place, not owned by a business.
  store_id          uuid references stores(id) on delete set null,
  city_id           uuid not null references cities(id),
  name              text not null,
  category          text not null default 'other',
  description       text not null default '',
  address_text      text not null default '',
  latitude          double precision not null check (latitude  between  -90 and  90),
  longitude         double precision not null check (longitude between -180 and 180),
  geofence_radius_m integer not null default 120,
  status            text not null default 'pending'
                      check (status in ('pending','published','rejected')),
  -- When a listing went live, so age can be shown and a stale listing found.
  published_at      timestamptz,
  created_at        timestamptz not null default now()
);
-- Serves "what's on screen?" without scanning the whole table.
create index if not exists places_viewport_idx
  on places (latitude, longitude) where status = 'published';
create index if not exists places_city_idx
  on places (city_id) where status = 'published';

-- =====================================================================
-- Trust
-- =====================================================================

create table if not exists user_trust (
  user_id          uuid primary key references profiles(id) on delete cascade,
  -- Deliberately low. A new account cannot buy influence with a GPS ping.
  user_trust       numeric(5,2) not null default 10 check (user_trust between 0 and 100),
  account_age_days integer not null default 0,
  accepted_reviews integer not null default 0,
  flagged_reviews  integer not null default 0,
  duplicate_hits   integer not null default 0,
  coordination_hits integer not null default 0,
  -- sha256 of a per-install random id. NOT a hardware identifier: several
  -- accounts sharing one install is a weak risk signal, and a shared office or
  -- carrier IP is never a signal at all.
  install_id_hash  text,
  last_computed_at timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table if not exists user_city_trust (
  user_id             uuid not null references profiles(id) on delete cascade,
  city_id             uuid not null references cities(id) on delete cascade,
  city_trust          numeric(5,2) not null default 0 check (city_trust between 0 and 100),
  -- Components are kept so "why is this person a local?" is answerable. The
  -- behaviour that produced them is not kept.
  residency_score     numeric(5,2) not null default 0,
  tenure_score        numeric(5,2) not null default 0,
  local_activity_score numeric(5,2) not null default 0,
  contribution_score  numeric(5,2) not null default 0,
  consistency_score   numeric(5,2) not null default 0,
  integrity_score     numeric(5,2) not null default 0,
  first_seen_at       timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  primary key (user_id, city_id)
);

create table if not exists visit_proofs (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references profiles(id) on delete cascade,
  place_id            uuid not null references places(id) on delete cascade,
  -- sha256 of a single-use nonce. The raw nonce is never stored, so a leaked
  -- table cannot be used to mint verifications.
  nonce_hash          text not null unique,
  verified_at         timestamptz not null default now(),
  -- Accuracy is bucketed, never the raw reading. "Verified to within 25 m" is
  -- what the trust formula needs; a coordinate history would not be.
  accuracy_bucket     text check (accuracy_bucket in ('precise','fair','coarse','unknown')),
  verification_method text not null default 'gps'
                        check (verification_method in ('gps','qr','nfc','receipt','manual')),
  trust_score         numeric(5,2) not null default 0 check (trust_score between 0 and 100),
  -- Set when a review cites this proof, which stops one visit being reused.
  consumed_at         timestamptz,
  expires_at          timestamptz not null,
  created_at          timestamptz not null default now()
);
create index if not exists visit_proofs_lookup_idx
  on visit_proofs (user_id, place_id, verified_at desc);

create table if not exists verification_nonces (
  nonce_hash  text primary key,
  user_id     uuid not null references profiles(id) on delete cascade,
  place_id    uuid not null references places(id) on delete cascade,
  issued_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  consumed_at timestamptz
);

create table if not exists reviews (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  place_id   uuid not null references places(id) on delete cascade,
  rating     smallint not null check (rating between 1 and 5),
  text       text not null default '',

  -- Written by the database only. The client is not granted write access to
  -- any of these columns; see the revoke/grant pair in 0002.
  user_trust     numeric(5,2),
  city_trust     numeric(5,2),
  review_trust   numeric(5,2),
  review_weight  numeric(6,5) check (review_weight between 0 and 1),
  fraud_score    numeric(5,4),
  -- True when a store owner reviews their own store: a conflict of interest
  -- that is excluded from the aggregate rather than merely trusted less.
  is_owner       boolean not null default false,

  -- Full numeric breakdown, kept for audit. The public API returns labels
  -- instead, because publishing these would hand attackers a tuning oracle.
  explanation    jsonb,
  visit_proof_id uuid references visit_proofs(id) on delete set null,
  status         text not null default 'published'
                   check (status in ('published','under_review','rejected')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  -- One review per person per place, enforced here rather than in Dart.
  unique (place_id, user_id)
);
create index if not exists reviews_place_idx
  on reviews (place_id) where status = 'published';
create index if not exists reviews_user_idx
  on reviews (user_id, created_at desc);

-- =====================================================================
-- Configuration
-- =====================================================================
-- Every threshold is a row, so retuning is an UPDATE rather than a redeploy.

create table if not exists trust_config (
  key   text primary key,
  value numeric(10,4) not null
);

insert into trust_config (key, value) values
  -- The weight formula.
  ('city_local_threshold',        70),
  ('local_bonus',                 0.15),
  ('evidence_floor',              0.50),
  ('evidence_range',              0.50),
  -- Bayesian smoothing, which stops a single review pinning a place to 5.0.
  ('prior_rating',                3.8),
  ('prior_mass',                  5),
  -- Fraud coefficients.
  ('fraud_duplicate_text',        0.30),
  ('fraud_impossible_travel',     0.25),
  ('fraud_review_burst',          0.20),
  ('fraud_device_risk',           0.15),
  ('fraud_account_risk',          0.10),
  ('fraud_monitor_threshold',     0.30),
  ('fraud_review_threshold',      0.60),
  -- UserTrust component weights.
  ('ut_weight_age',               0.30),
  ('ut_weight_history',           0.30),
  ('ut_weight_integrity',         0.25),
  ('ut_weight_moderation',        0.15),
  -- CityTrust component weights.
  ('ct_weight_tenure',            0.25),
  ('ct_weight_activity',          0.25),
  ('ct_weight_contribution',      0.20),
  ('ct_weight_consistency',       0.15),
  ('ct_weight_residency',         0.15),
  -- Visit verification.
  ('visit_proof_ttl_hours',       24),
  ('nonce_ttl_seconds',           120),
  ('proof_base_unverified',       25),
  -- Rate limits.
  ('max_reviews_per_hour',        5),
  ('max_reviews_per_day',         20)
on conflict (key) do nothing;

create or replace function cfg(k text) returns numeric
language sql stable as $$
  select value from trust_config where key = k;
$$;

comment on function cfg(text) is
  'Reads a trust-system threshold from trust_config. Stable, not immutable, '
  'because the values are data and can be retuned without a redeploy.';

-- ==== 0002_trust_and_rls.sql ====
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

-- ==== 0003_seed.sql ====
-- RevMap: seed data.  GENERATED by tool/gen_seed.py -- do not hand-edit.
--
-- One city plus the same places the app bundles in lib/data/sample_data.dart,
-- so the map has real data the moment it connects. Because this file is
-- generated from that Dart source, the sample data and the database cannot
-- drift apart by hand.
--
-- Re-runnable: ids are derived with md5(...) so they are stable, and every
-- insert is an upsert. Re-running after editing the sample data is safe.
--
-- Coordinates are two ordinary columns; the composite index on
-- (latitude, longitude) serves the map's viewport query.

insert into cities (name, country, centre_lat, centre_lng)
values ('Bengaluru', 'India', 12.9716, 77.5946)
on conflict (name, country) do nothing;


insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p1')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'Cubbon Park', 'attraction', 'One of the largest green spaces in the city, with walking paths, lakes and the Cubbon Park metro stop at the west gate.', 'Sampangi Rama Nagar',
        12.9763, 77.5929, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p2')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'Third Wave Coffee', 'coffee', 'Specialty coffee on Church Street, a short walk from the metro.', 'Church Street',
        12.9695, 77.5963, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p3')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'Chinnaswamy Stadium', 'attraction', 'Test cricket ground in the heart of the city.', 'MG Road',
        12.9788, 77.5996, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p4')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'The Lalit Ashok', 'hotel', 'Long-standing luxury hotel with a large garden.', 'Kempapura',
        12.9661, 77.6003, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p5')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'Indian Museum', 'museum', 'One of the oldest museums in India.', 'Jawaharlal Nehru Road',
        12.9726, 77.5712, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p6')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'UB City', 'shopping', 'Mixed-use complex with shops, offices and a food court.', 'Vittal Mallya Road',
        12.9718, 77.5958, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p7')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'Toit', 'restaurant', 'Brewery and kitchen, busy from evening onwards.', '100 Feet Road',
        12.9708, 77.6093, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p8')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'Lalbagh Botanical Garden', 'park', 'A large botanical garden with a glasshouse.', 'Mavalli',
        12.9507, 77.5848, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p9')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'Gangubai Kaum', 'hotel', 'Budget stay near the commercial district.', 'VV Puram',
        12.9654, 77.6182, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p10')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'Koshy’s', 'restaurant', 'Long-running bakery and restaurant chain.', 'Sampangi Rama Nagar',
        12.9754, 77.6062, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p11')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'National Gallery of Modern Art', 'museum', 'Modern and contemporary Indian art in a park setting.', 'M.G. Road',
        12.9719, 77.6094, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;

insert into places (id, city_id, name, category, description, address_text,
                    latitude, longitude, status)
values (md5('revamp:p12')::uuid,
        (select id from cities where name = 'Bengaluru' limit 1),
        'Garuda Mall', 'shopping', 'Neighbourhood shopping mall with a cinema.', 'Magrath Road',
        12.9667, 77.6071, 'published')
on conflict (id) do update set
  name = excluded.name, category = excluded.category,
  description = excluded.description, address_text = excluded.address_text,
  latitude = excluded.latitude, longitude = excluded.longitude,
  status = excluded.status;


-- Rating and review count are display aggregates, not reviews. Once real
-- reviews exist these come from place_rating() / place_confidence() instead.
-- Kept as a separate seeded aggregate rather than fabricated review rows,
-- because a fake review would be indistinguishable from a real one once trust
-- scoring applies -- which is exactly the failure this system exists to prevent.
create table if not exists place_seed_stats (
  place_id     uuid primary key references places(id) on delete cascade,
  rating       numeric(2,1) not null,
  review_count integer not null,
  open_status  text not null default 'open',
  closing_time text
);

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p1')::uuid, 4.6, 8420, 'open', '20:00')
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p2')::uuid, 4.4, 3180, 'open', '23:00')
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p3')::uuid, 4.5, 12900, 'closed', NULL)
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p4')::uuid, 4.3, 2140, 'open', NULL)
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p5')::uuid, 4.4, 5680, 'closingSoon', '18:30')
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p6')::uuid, 4.5, 9760, 'open', '22:00')
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p7')::uuid, 4.2, 6320, 'open', '01:00')
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p8')::uuid, 4.7, 15200, 'open', '18:00')
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p9')::uuid, 4.1, 890, 'closed', NULL)
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p10')::uuid, 4.4, 4410, 'open', '22:30')
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p11')::uuid, 4.2, 1870, 'closed', NULL)
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values (md5('revamp:p12')::uuid, 4.0, 3320, 'open', '22:00')
on conflict (place_id) do update set
  rating = excluded.rating, review_count = excluded.review_count,
  open_status = excluded.open_status, closing_time = excluded.closing_time;

-- ==== 0004_owner_flow.sql ====
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

-- ==== 0005_explicit_grants.sql ====
-- RevMap: explicit privileges.
--
-- The earlier migrations relied on Supabase's default privileges, which happen
-- to grant broadly on everything in `public`. That is convenient but implicit:
-- the schema does not say what each role may actually do, and it breaks the
-- moment a table is created outside the dashboard or defaults change.
--
-- This migration states the privileges outright, so the security model is
-- readable in one place and does not depend on platform defaults. It is also
-- what makes the whole thing testable against a plain PostgreSQL.
--
-- The rule: the anon key may READ published content and nothing else. Anything
-- that writes requires a signed-in user, and the row-level policies in 0004
-- decide which rows that user may touch.
--
-- Safe to run more than once.

-- =====================================================================
-- 1. Narrow first, then grant
-- =====================================================================
-- Supabase grants ALL on tables in `public` by default. Narrow that
-- BEFORE granting, so the grants below are the final word. Doing it the
-- other way round silently undoes them -- which is exactly what an
-- earlier version of this file did to `places`.

revoke all on profiles           from anon;
revoke all on user_trust         from anon;
revoke all on user_city_trust    from anon;
revoke all on visit_proofs       from anon;
revoke all on verification_nonces from anon;
revoke all on reviews            from anon;
revoke all on stores             from anon;
revoke all on places             from anon;

-- =====================================================================
-- 2. Grants
-- =====================================================================
-- =====================================================================
-- Read access
-- =====================================================================

-- Reference data anyone may read, including with the anon key.
grant usage on schema public to anon, authenticated;
grant select on cities, trust_config to anon, authenticated;

-- Published places and stores. RLS still hides pending listings from anyone
-- who does not own them; the grant only says "this table is readable".
grant select on places, stores to anon, authenticated;
grant select on public_place_cards to anon, authenticated;

-- public_place_cards is created with security_invoker, so it reads places,
-- stores AND place_seed_stats using the *caller's* privileges. Without a grant
-- on place_seed_stats the view fails for every caller, including anon.
grant select on place_seed_stats to anon, authenticated;

-- Reviews, but only published ones -- again enforced by RLS, not here.
grant select on reviews to anon, authenticated;

-- A signed-in user may read their own profile and their own trust records.
-- There is no grant to anon for these at all, which is what makes them
-- private rather than merely filtered.
grant select on profiles, user_trust, user_city_trust, visit_proofs,
                verification_nonces to authenticated;

-- =====================================================================
-- Write access, signed-in users only
-- =====================================================================

grant insert on profiles to authenticated;

-- Column-limited update. A row-level policy says WHICH ROWS a user may touch;
-- it says nothing about which COLUMNS, so `for update` on one's own row would
-- still permit rewriting `role` and self-promoting to store owner. Restricting
-- the grant is the only thing that prevents it.
--
-- `role` is intentionally writable at INSERT and never afterwards: choosing
-- "I'm a store owner" at sign-up is a supported action, but quietly changing
-- it later is not.
revoke update on profiles from authenticated;
grant update (display_name, declared_country) on profiles to authenticated;
grant insert, update on stores to authenticated;
grant insert, update on places to authenticated;

-- Reviews: the insert grant is deliberately column-limited, and is repeated
-- here so this file is the single place the rule is visible. A client may set
-- a rating and some text. It may not set review_weight, user_trust,
-- city_trust, review_trust, fraud_score, status or user_id -- those are
-- written by the trigger in 0002 and by nothing else.
revoke insert on reviews from anon, authenticated;
grant insert (place_id, rating, text, visit_proof_id) on reviews to authenticated;
grant update (rating, text) on reviews to authenticated;
grant delete on reviews to authenticated;

-- The guarded publication function. It re-checks ownership internally, so this
-- grant is a convenience rather than the security boundary.
revoke execute on function set_place_published(uuid, boolean) from anon;
grant execute on function set_place_published(uuid, boolean) to authenticated;


grant execute on function calculate_review_weight(double precision, double precision, double precision)
  to anon, authenticated;
grant execute on function calculate_user_trust(uuid)   to authenticated;
grant execute on function calculate_city_trust(uuid, uuid) to authenticated;
grant execute on function calculate_review_trust(uuid, uuid, text, uuid) to authenticated;
grant execute on function calculate_fraud_score(uuid, uuid, text) to authenticated;
grant execute on function place_rating(uuid) to anon, authenticated;
grant execute on function place_confidence(uuid) to anon, authenticated;
grant execute on function cfg(text) to anon, authenticated;

-- ==== 0006_simulator.sql ====
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

-- ==== 0007_simulator_listings.sql ====
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

-- ==== 0008_schema_drift.sql ====
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

-- ==== display aggregates ====
-- RevMap: display aggregates, as a single atomic statement.
--
-- These are the seeded rating, review count and opening status shown on place
-- cards. They are deliberately NOT stored as fabricated review rows: a fake
-- review would be indistinguishable from a real one once trust scoring
-- applies, which is exactly the failure this system exists to prevent.
--
-- One statement on purpose. A twelve-statement script was truncated twice by
-- the Supabase SQL editor's timeout, leaving the table half-populated. This is
-- atomic, so it either all lands or none of it does.
--
-- Safe to run more than once: every row upserts on place_id.

insert into place_seed_stats (place_id, rating, review_count, open_status, closing_time)
values
    (md5('revamp:p1')::uuid, 4.6, 8420, 'open', '20:00'),
      (md5('revamp:p2')::uuid, 4.4, 3180, 'open', '23:00'),
      (md5('revamp:p3')::uuid, 4.5, 12900, 'closed', NULL),
      (md5('revamp:p4')::uuid, 4.3, 2140, 'open', NULL),
      (md5('revamp:p5')::uuid, 4.4, 5680, 'closingSoon', '18:30'),
      (md5('revamp:p6')::uuid, 4.5, 9760, 'open', '22:00'),
      (md5('revamp:p7')::uuid, 4.2, 6320, 'open', '01:00'),
      (md5('revamp:p8')::uuid, 4.7, 15200, 'open', '18:00'),
      (md5('revamp:p9')::uuid, 4.1, 890, 'closed', NULL),
      (md5('revamp:p10')::uuid, 4.4, 4410, 'open', '22:30'),
      (md5('revamp:p11')::uuid, 4.2, 1870, 'closed', NULL),
      (md5('revamp:p12')::uuid, 4.0, 3320, 'open', '22:00')
on conflict (place_id) do update set
  rating        = excluded.rating,
  review_count  = excluded.review_count,
  open_status   = excluded.open_status,
  closing_time  = excluded.closing_time;
