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
