-- Preserve the name bound to each immutable photo revision after later edits.
-- Existing rows predate this snapshot; do not invent their historical names.
alter table bank.identity_evidence
  add column profile_name text check (profile_name is null or char_length(btrim(profile_name)) between 1 and 120);
comment on column bank.identity_evidence.profile_name is
  'Immutable name snapshot from the locked customer record at reservation. NULL identifies legacy rows whose original name was not retained; never backfill from the current profile.';
grant insert (profile_name) on bank.identity_evidence to nene_api;
drop policy api_insert_identity_evidence on bank.identity_evidence;
create policy api_insert_identity_evidence on bank.identity_evidence for insert to nene_api with check (
  profile_name is not null
);
