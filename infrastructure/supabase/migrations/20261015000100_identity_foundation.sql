-- Foundation for BR-01/BR-03 and TR-03. These records are not banking accounts.
-- Auth identity creation and officer provisioning remain future backend work.
-- No Auth trigger grants application roles from user-controlled metadata.

create schema bank;

create role nene_api
  nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls;

-- The migration administrator can SET ROLE for privilege tests/maintenance.
-- No client role receives membership, and privileges are not inherited implicitly.
grant nene_api to postgres with inherit false, set true;

revoke all on schema bank from public, anon, authenticated, service_role;
grant usage on schema bank to nene_api;

create table bank.user_profiles (
  id uuid primary key references auth.users (id) on delete restrict,
  display_name text not null check (
    char_length(btrim(display_name)) between 1 and 120
  ),
  role text not null check (role in ('customer', 'officer')),
  status text not null default 'active' check (status in ('active', 'disabled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table bank.user_profiles is
  'Server-controlled application profile; Supabase Auth identity alone grants no banking access.';
comment on column bank.user_profiles.updated_at is
  'Future authorized profile updates must update this timestamp; no profile writes are exposed yet.';

-- Explicit revocation also handles any platform default table grants.
-- Each future migration must make its own grants explicit.
revoke all on table bank.user_profiles from public, anon, authenticated, service_role;
grant select on table bank.user_profiles to nene_api;

alter table bank.user_profiles enable row level security;
alter table bank.user_profiles force row level security;

-- NestJS is the trusted boundary and must query by verified Auth subject.
-- The role has SELECT only: it cannot create customers or change privileges.
create policy api_can_read_profiles
  on bank.user_profiles
  for select
  to nene_api
  using (true);

-- Private evidence storage is prepared, but no upload/eKYC flow exists yet.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'identity-evidence',
  'identity-evidence',
  false,
  10485760,
  array['image/jpeg', 'image/png']
);

-- These restrictive policies prevent a later generic permissive mobile policy
-- from accidentally opening this bucket. Backend-controlled access is future work.
create policy identity_evidence_no_mobile_objects
  on storage.objects
  as restrictive
  for all
  to anon, authenticated
  using (bucket_id <> 'identity-evidence')
  with check (bucket_id <> 'identity-evidence');

create policy identity_evidence_no_mobile_bucket
  on storage.buckets
  as restrictive
  for all
  to anon, authenticated
  using (id <> 'identity-evidence')
  with check (id <> 'identity-evidence');
