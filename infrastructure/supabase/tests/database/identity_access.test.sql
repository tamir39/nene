-- BR-01/BR-03 foundation checks; does not establish completed role/eKYC flows.
begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(24);

-- Synthetic test-only identity, rolled back together with all test changes.
insert into auth.users (id, email)
values ('d5000000-0000-4000-8000-000000000001', 'access-test@example.invalid');
insert into bank.user_profiles (id, display_name, role)
values ('d5000000-0000-4000-8000-000000000001', 'Access test customer', 'customer');

select ok(not has_schema_privilege('anon', 'bank', 'USAGE'), 'Anonymous clients cannot use the bank schema');
select ok(not has_schema_privilege('authenticated', 'bank', 'USAGE'), 'Authenticated clients cannot use the bank schema');
select ok(not has_table_privilege('anon', 'bank.user_profiles', 'SELECT'), 'Anonymous clients have no profile SELECT grant');
select ok(not has_table_privilege('authenticated', 'bank.user_profiles', 'SELECT'), 'Authenticated clients have no profile SELECT grant');
select ok(not has_table_privilege('authenticated', 'bank.user_profiles', 'UPDATE'), 'Authenticated clients cannot grant themselves a role');
select ok(has_schema_privilege('nene_api', 'bank', 'USAGE'), 'Backend role can use the bank schema');
select ok(has_table_privilege('nene_api', 'bank.user_profiles', 'SELECT'), 'Backend role has profile SELECT grant');
select ok(not has_table_privilege('nene_api', 'bank.user_profiles', 'INSERT'), 'Backend has no unrestricted whole-table profile INSERT grant');
select ok(not has_table_privilege('nene_api', 'bank.user_profiles', 'UPDATE'), 'Backend has no unrestricted whole-table profile UPDATE grant');
select ok(not has_table_privilege('nene_api', 'bank.user_profiles', 'DELETE'), 'Backend foundation has no profile DELETE grant');
select ok(
  (select not rolsuper and not rolcreaterole and not rolcreatedb and not rolbypassrls from pg_roles where rolname = 'nene_api'),
  'Backend role cannot administer or bypass row security'
);
select ok(
  (select relrowsecurity and relforcerowsecurity from pg_class where oid = 'bank.user_profiles'::regclass),
  'Profiles enforce row security'
);
select is(
  (select public from storage.buckets where id = 'identity-evidence'),
  false,
  'Identity evidence bucket is private'
);

-- pgTAP must remain callable after SET ROLE; these grants are test-only and rolled back.
grant usage on schema extensions to nene_api;

set local role anon;
select throws_ok('select * from bank.user_profiles', '42501', 'permission denied for schema bank', 'Anonymous direct profile query fails');
reset role;

set local role authenticated;
select throws_ok('select * from bank.user_profiles', '42501', 'permission denied for schema bank', 'Authenticated direct profile query fails');
reset role;

set local role nene_api;
select is(
  (select display_name from bank.user_profiles where id = 'd5000000-0000-4000-8000-000000000001'),
  'Access test customer',
  'Backend role reads an existing profile through RLS'
);
select throws_ok(
  $$update bank.user_profiles set role = 'officer' where id = 'd5000000-0000-4000-8000-000000000001'$$,
  '42501', 'permission denied for table user_profiles',
  'Backend cannot modify a profile role'
);
select throws_ok(
  $$delete from bank.user_profiles where id = 'd5000000-0000-4000-8000-000000000001'$$,
  '42501', 'permission denied for table user_profiles',
  'Backend foundation cannot delete profiles'
);
reset role;

-- Add broad policies inside this rollback-only test to prove restrictive bucket
-- policies still protect evidence if future generic permissive policies appear.
create policy test_mobile_can_read_buckets on storage.buckets for select to authenticated using (true);
create policy test_mobile_can_read_objects on storage.objects for select to authenticated using (true);
create policy test_mobile_can_write_objects on storage.objects for insert to authenticated with check (true);
insert into storage.objects (bucket_id, name)
values ('identity-evidence', 'synthetic-no-file.png');

set local role authenticated;
select is((select count(*) from storage.buckets where id = 'identity-evidence'), 0::bigint, 'Mobile role cannot inspect identity bucket despite permissive policy');
select is((select count(*) from storage.objects where bucket_id = 'identity-evidence'), 0::bigint, 'Mobile role cannot read identity object metadata despite permissive policy');
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values ('identity-evidence', 'blocked.png')$$,
  '42501', null,
  'Mobile role cannot upload identity object metadata despite permissive policy'
);
reset role;

select throws_ok(
  $$insert into bank.user_profiles (id, display_name, role) values ('d5000000-0000-4000-8000-000000000002', 'No auth identity', 'customer')$$,
  '23503', null,
  'Profiles require an existing Auth identity'
);
select throws_ok(
  $$update bank.user_profiles set role = 'administrator' where id = 'd5000000-0000-4000-8000-000000000001'$$,
  '23514', null,
  'Only the two assignment roles are accepted'
);
select throws_ok(
  $$update bank.user_profiles set status = 'uncontrolled' where id = 'd5000000-0000-4000-8000-000000000001'$$,
  '23514', null,
  'Profile status must be recognized'
);

select * from finish();
rollback;
