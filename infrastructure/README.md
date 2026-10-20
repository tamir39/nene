# Nene database

This directory supports BR-01/BR-02, the login part of BR-03, partial BR-05 and TR-03. It contains local Supabase configuration, forward PostgreSQL migrations and database access tests. The current schema supports authorized customer creation/contact edits, initial zero-balance checking accounts, durable creation requests and profile edit audit records. eKYC, transaction 2FA, other account behavior and financial operations remain unimplemented.

## Access boundaries

- `bank.user_profiles` links an existing Supabase Auth identity to a server-controlled customer/officer role and active/disabled status. No sign-up trigger trusts user metadata or assigns roles.
- The `bank` schema is absent from the Data API exposure and search paths. `anon`, `authenticated`, and `service_role` have no schema/table grants.
- The `nene_api` database role reads profiles/accounts and has narrow column grants for customer creation/contact edits. It cannot choose/change a profile role, update sign-in email or status, set/change balances, delete rows, create roles/databases or bypass RLS. NestJS must still validate the session, check officer permissions and query the verified customer subject; this shared database login is a backend credential, not an individual customer identity.
- `bank.banking_accounts` stores generated account numbers, owner, type, explicit currency and integer minor-unit balance. The API creates checking/VND accounts at zero; other types/currencies remain possible schema values for later approved work. No balance mutation grant or endpoint exists.
- `bank.customer_creation_requests` durably reserves customer/account UUIDs before Auth creation. Its reserved IDs deliberately have no foreign key until creation completes. A salted scrypt fingerprint verifies retry payloads without storing plaintext passwords. Request identity fields are immutable to the API.
- `bank.profile_edit_audit` is append-only to the API. It records actor, customer, edited field names and the stated reason for officer changes; no credential or financial data is logged.
- `identity-evidence` is private. Restrictive storage policies block mobile roles, including if a future generic permissive policy is added. No evidence upload/download endpoint is implemented yet.
- The initial identity bucket accepts JPEG/PNG files up to 10 MiB. These are adjustable implementation limits, not PDF requirements.
- Every future table migration must explicitly define grants and RLS; do not depend on Supabase default privileges. Keep banking data accessible through NestJS only.

## Local configuration

`supabase/config.toml` was generated with the repository-pinned Supabase CLI and narrowed to the required services. PostgreSQL 17, Auth, Storage, Studio, and a local-only email inbox are configured. Public sign-up and anonymous sign-in are disabled. Realtime, Edge Functions, analytics, and vector storage are disabled. Email/password session authentication does not implement eKYC or transaction-bound 2FA.

The CLI uses ports 54320-54324 for its shadow database, API, database, Studio, and email inbox. API/database addresses refer to the development machine; Android emulator networking is configured separately in the app.

No Supabase cloud project is linked or provisioned. Local config does not automatically configure a later hosted project. Hosted signup settings, schema exposure, grants, private Storage, secrets, and database connection/TLS settings must be verified when hosting is explicitly set up.

## Local API credential

After the local Supabase stack is running and migrations are applied, the root setup workflow calls `scripts/configure-local-api.mjs`. It targets only Docker container `supabase_db_nene-local`, checks that it is a running Supabase PostgreSQL container, enables login on `nene_api`, and creates a randomly generated password in ignored `.env.api.local`. Repeated runs reuse that password. It neither creates customers nor grants additional privileges.

The script never accepts a remote database URL, prints credentials, or commits them. The root setup workflow uses the generated values to configure NestJS. SSL is disabled only for this local loopback connection. Never reuse this generated file in a hosted environment. A malformed or unexpected existing local configuration causes setup to stop rather than overwriting it.

## Verification

`supabase/tests/database/identity_access.test.sql` contains 24 pgTAP assertions for schema/table access, role restrictions, an actual backend profile read, denied privileged writes, private storage protection, and profile integrity. `customer_accounts.test.sql` adds 32 assertions covering allowed customer/contact writes, role/email/balance restrictions, account ownership, request uniqueness, and append-only audit records. All synthetic test rows and temporary policies are rolled back. These tests require the local database and both migrations; they do not exercise a hosted project or prove complete assignment features.

The local test runner, `scripts/test-local-db.mjs`, sends both tracked SQL tests to PostgreSQL inside the named Docker container. It fails for a SQL/process error, a failing TAP assertion, a missing/incomplete plan, or a missing rollback. This avoids a CLI-specific connection problem observed with Supabase CLI 2.121.0 on this Windows machine: `supabase test db --workdir infrastructure` timed out or terminated during connection to the local database. The underlying CLI issue has not been diagnosed; the Docker runner is the local test path. Current passing-run evidence is recorded in [SETUP.md](../docs/SETUP.md).

The root README records verified setup/build/test commands and any environment limitations. Do not run a database reset against an existing development database merely to apply later changes; apply forward migrations deliberately.

## References

- [Supabase CLI configuration](https://supabase.com/docs/guides/local-development/cli/config)
- [Supabase database testing](https://supabase.com/docs/guides/database/testing)
- [Supabase Storage access control](https://supabase.com/docs/guides/storage/security/access-control)
- [Supabase PostgreSQL roles](https://supabase.com/docs/guides/database/postgres/roles)
