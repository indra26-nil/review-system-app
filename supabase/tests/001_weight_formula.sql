-- RevMap: verification of the trust formula against the expected values in the
-- specification. Run against a database that has had 0001 + 0002 applied.
--
-- Each case states the inputs, the spec's expected weight, and what the
-- implementation actually produced. A mismatch is a bug, so every case is
-- written to fail loudly rather than to look approximately right.
--
--   psql -d revamp -f supabase/tests/001_weight_formula.sql

\pset footer off
\echo '=== Spec §18 table: review_weight ==='

do $$
declare
  cases constant text[][] := array[
    -- label,                         user, city, review, expected
    ['A  local + trusted + verified',      '90', '90', '95',  '0.9750'],
    ['B  trusted visitor + verified',      '90', '30', '95',  '0.8775'],
    ['C  trusted local + remote',          '90', '90', '30',  '0.6500'],
    ['D  normal local + verified',         '60', '85', '90',  '0.7125'],
    ['E  normal visitor + verified',       '60', '20', '90',  '0.5700'],
    ['F  new account + verified',          '30', '20', '95',  '0.2925'],
    ['G  weak account + suspicious visit', '20', '20', '95',  '0.1950'],
    ['H  trusted visitor + perfect',       '98', '20', '100', '0.9800'],
    ['   trusted local + no evidence',    '100','100','0',   '0.5000']
  ];
  c text[];
  got numeric(6,4);
  expected numeric;
  failures int := 0;
begin
  foreach c slice 1 in array cases loop
    got      := calculate_review_weight(c[2]::float, c[3]::float, c[4]::float);
    expected := c[5]::numeric;
    if got = expected then
      raise notice 'PASS  %  -> %', rpad(c[1], 34), got;
    else
      failures := failures + 1;
      raise exception 'FAIL  %  expected % but got %', c[1], expected, got;
    end if;
  end loop;

  -- §38: the threshold boundary, where an off-by-one would hide.
  raise notice '';
  raise notice '=== Spec §38: boundary and clamping ===';

  if calculate_review_weight(50, 69, 100) = 0.5000 then
    raise notice 'PASS  city_trust 69 -> no bonus            -> 0.5000';
  else
    raise exception 'FAIL  city_trust 69 should not receive the bonus';
  end if;

  if calculate_review_weight(50, 70, 100) = 0.6500 then
    raise notice 'PASS  city_trust 70 -> bonus applied      -> 0.6500';
  else
    raise exception 'FAIL  city_trust 70 must receive the local bonus';
  end if;

  if calculate_review_weight(-5, 0, 0) = 0 then
    raise notice 'PASS  negative input clamps to zero';
  else
    raise exception 'FAIL  negative input must clamp to 0';
  end if;

  if calculate_review_weight(500, 200, 200) = 1.0 then
    raise notice 'PASS  over-100 input clamps to one';
  else
    raise exception 'FAIL  over-100 input must clamp to 1.0';
  end if;

  if failures > 0 then
    raise exception '% case(s) failed', failures;
  end if;

  raise notice '';
  raise notice '=== All % cases match the specification ===', array_length(cases, 1);
end $$;
