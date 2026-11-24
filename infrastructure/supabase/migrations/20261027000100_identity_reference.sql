-- BR-01/BR-03/TR-03: private reference enrollment and officer review only.
-- Reference acceptance is not an electronic match, live-presence check or 2FA.
create table bank.identity_cases (
  id uuid primary key,
  customer_id uuid not null unique references bank.user_profiles (id) on delete restrict,
  state text not null default 'draft' check (state in ('draft', 'submitted', 'needs_changes', 'reference_accepted')),
  version integer not null default 1 check (version > 0),
  revision integer not null default 1 check (revision > 0),
  profile_name text not null check (char_length(btrim(profile_name)) between 1 and 120),
  evidence_id uuid,
  notice_version text not null check (char_length(notice_version) between 1 and 80),
  acknowledged_by uuid not null references bank.user_profiles (id) on delete restrict,
  acknowledged_role text not null check (acknowledged_role in ('customer', 'officer')),
  correction_reason text check (correction_reason is null or char_length(btrim(correction_reason)) between 5 and 500),
  reviewed_by uuid references bank.user_profiles (id) on delete restrict,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  check (state not in ('submitted', 'reference_accepted') or evidence_id is not null),
  check (state <> 'reference_accepted' or (reviewed_by is not null and reviewed_at is not null))
);
comment on table bank.identity_cases is
  'One current reference case per customer. Version protects commands; revision binds a photo to the reviewed name. Seven-day expiry is a local coursework policy, not a PDF rule.';
comment on column bank.identity_cases.evidence_id is
  'Backend validates ownership, revision and readiness against identity_evidence in the same transaction. Clients cannot supply arbitrary evidence references.';

create table bank.identity_evidence (
  id uuid primary key,
  case_id uuid not null references bank.identity_cases (id) on delete restrict,
  revision integer not null check (revision > 0),
  object_key text not null unique check (char_length(object_key) between 1 and 255),
  content_hash text not null check (content_hash ~ '^[a-f0-9]{64}$'),
  content_type text not null check (content_type in ('image/jpeg', 'image/png')),
  byte_size integer not null check (byte_size between 1 and 10485760),
  status text not null default 'pending' check (status in ('pending', 'ready')),
  created_at timestamptz not null default now(),
  ready_at timestamptz,
  expires_at timestamptz not null,
  deleted_at timestamptz,
  check (status <> 'ready' or ready_at is not null)
);
create index identity_evidence_case on bank.identity_evidence (case_id, revision);
create index identity_evidence_cleanup on bank.identity_evidence (expires_at) where deleted_at is null;
comment on table bank.identity_evidence is
  'Private Storage reservation and tombstone metadata; no image bytes. Object/hash/owner/revision are immutable to the API role. Storage deletion precedes deleted_at acknowledgement.';

create table bank.identity_commands (
  actor_id uuid not null references bank.user_profiles (id) on delete restrict,
  idempotency_key uuid not null,
  customer_id uuid not null references bank.user_profiles (id) on delete restrict,
  action text not null check (action in ('start', 'upload', 'submit', 'accept_reference', 'request_changes')),
  payload_hash text not null check (payload_hash ~ '^[a-f0-9]{64}$'),
  case_id uuid references bank.identity_cases (id) on delete restrict,
  evidence_id uuid references bank.identity_evidence (id) on delete restrict,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (actor_id, idempotency_key)
);
comment on table bank.identity_commands is
  'Scoped command retries; a key cannot be reassigned to another actor, customer, action or payload. No image or credential is retained here.';

create table bank.identity_reviews (
  id uuid primary key,
  case_id uuid not null references bank.identity_cases (id) on delete restrict,
  actor_id uuid references bank.user_profiles (id) on delete restrict,
  revision integer not null check (revision > 0),
  action text not null check (action in ('accept_reference', 'request_changes', 'name_changed', 'expired')),
  reason text check (reason is null or char_length(btrim(reason)) between 5 and 500),
  created_at timestamptz not null default now(),
  check ((action in ('name_changed', 'expired') and actor_id is null)
    or (action in ('accept_reference', 'request_changes') and actor_id is not null)),
  check (action = 'accept_reference' or reason is not null)
);
create index identity_reviews_case on bank.identity_reviews (case_id, created_at, id);
comment on table bank.identity_reviews is
  'Append-only reference decisions. NULL actor is reserved for system invalidation; the existing profile edit audit identifies the officer responsible for a name edit.';

revoke all on bank.identity_cases, bank.identity_evidence, bank.identity_commands, bank.identity_reviews
  from public, anon, authenticated, service_role;
grant select on bank.identity_cases, bank.identity_evidence, bank.identity_commands, bank.identity_reviews to nene_api;
grant insert (id, customer_id, state, version, revision, profile_name, evidence_id, notice_version,
  acknowledged_by, acknowledged_role, correction_reason, reviewed_by, reviewed_at, expires_at)
  on bank.identity_cases to nene_api;
grant update (state, version, revision, profile_name, evidence_id, notice_version, acknowledged_by,
  acknowledged_role, correction_reason, reviewed_by, reviewed_at, expires_at, updated_at)
  on bank.identity_cases to nene_api;
grant insert (id, case_id, revision, object_key, content_hash, content_type, byte_size, status, ready_at, expires_at)
  on bank.identity_evidence to nene_api;
grant update (status, ready_at, deleted_at) on bank.identity_evidence to nene_api;
grant insert (actor_id, idempotency_key, customer_id, action, payload_hash, case_id, evidence_id, completed_at)
  on bank.identity_commands to nene_api;
grant update (case_id, evidence_id, completed_at) on bank.identity_commands to nene_api;
grant insert (id, case_id, actor_id, revision, action, reason) on bank.identity_reviews to nene_api;

alter table bank.identity_cases enable row level security;
alter table bank.identity_cases force row level security;
alter table bank.identity_evidence enable row level security;
alter table bank.identity_evidence force row level security;
alter table bank.identity_commands enable row level security;
alter table bank.identity_commands force row level security;
alter table bank.identity_reviews enable row level security;
alter table bank.identity_reviews force row level security;

-- NestJS verifies the session, active role, case ownership and command scope.
-- Database policies add structural checks; no client role can enter this schema.
create policy api_read_identity_cases on bank.identity_cases for select to nene_api using (true);
create policy api_insert_identity_cases on bank.identity_cases for insert to nene_api with check (
  exists (select 1 from bank.user_profiles where id = customer_id and role = 'customer' and status = 'active') and
  exists (select 1 from bank.user_profiles where id = acknowledged_by and role = acknowledged_role and status = 'active') and
  (acknowledged_role = 'officer' or acknowledged_by = customer_id)
);
create policy api_update_identity_cases on bank.identity_cases for update to nene_api using (true) with check (
  exists (select 1 from bank.user_profiles where id = customer_id and role = 'customer') and
  (acknowledged_role = 'officer' or acknowledged_by = customer_id)
);
create policy api_read_identity_evidence on bank.identity_evidence for select to nene_api using (true);
create policy api_insert_identity_evidence on bank.identity_evidence for insert to nene_api with check (true);
create policy api_update_identity_evidence on bank.identity_evidence for update to nene_api using (true) with check (true);
create policy api_read_identity_commands on bank.identity_commands for select to nene_api using (true);
create policy api_insert_identity_commands on bank.identity_commands for insert to nene_api with check (
  exists (select 1 from bank.user_profiles where id = customer_id and role = 'customer' and status = 'active') and
  exists (select 1 from bank.user_profiles where id = actor_id and status = 'active' and (role = 'officer' or id = customer_id))
);
create policy api_update_identity_commands on bank.identity_commands for update to nene_api using (true) with check (true);
create policy api_read_identity_reviews on bank.identity_reviews for select to nene_api using (true);
create policy api_append_identity_reviews on bank.identity_reviews for insert to nene_api with check (
  (actor_id is null and action in ('name_changed', 'expired')) or
  (action in ('accept_reference', 'request_changes') and exists (
    select 1 from bank.user_profiles where id = actor_id and role = 'officer' and status = 'active'
  ))
);

-- Name changes and reference invalidation commit together, including callers
-- other than today's HTTP controller. Contact-only updates do not invalidate.
create function bank.invalidate_reference_on_name_change() returns trigger
language plpgsql security invoker
set search_path = pg_catalog, bank
as $$
declare
  invalidated record;
begin
  if new.display_name is distinct from old.display_name then
    for invalidated in
      update bank.identity_cases
      set profile_name = new.display_name,
          version = version + 1,
          revision = revision + 1,
          state = case when state in ('submitted', 'reference_accepted') then 'needs_changes' else state end,
          evidence_id = null,
          correction_reason = 'Your name changed. Submit a new reference photo.',
          reviewed_by = null,
          reviewed_at = null,
          updated_at = now()
      where customer_id = new.id
      returning id, revision
    loop
      insert into bank.identity_reviews (id, case_id, actor_id, revision, action, reason)
      values (gen_random_uuid(), invalidated.id, null, invalidated.revision, 'name_changed',
              'Your name changed. Submit a new reference photo.');
    end loop;
  end if;
  return new;
end;
$$;
revoke all on function bank.invalidate_reference_on_name_change() from public, anon, authenticated, service_role;
grant execute on function bank.invalidate_reference_on_name_change() to nene_api;
create trigger identity_reference_name_changed
after update of display_name on bank.user_profiles
for each row execute function bank.invalidate_reference_on_name_change();
