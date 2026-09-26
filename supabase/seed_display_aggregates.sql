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
