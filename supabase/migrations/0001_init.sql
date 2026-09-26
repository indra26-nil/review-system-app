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
