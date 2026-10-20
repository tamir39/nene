# Nene API

This is the single NestJS backend selected for Nene. It establishes configuration,
session verification, customer/officer permissions, local synthetic customer
creation, requested officer profile edits, customer contact edits and own account
views. This supports BR-01/BR-02, the login part of BR-03, partial BR-05 and TR-03.
The first demo creates one zero-balance VND checking account. These are project
choices, not PDF rules. eKYC, saving/mortgage behavior, transaction 2FA, financial
operations, utilities, maps and chatbot remain to implement under
[SCOPE.md](../SCOPE.md).

## Local setup

Use Node.js 24 and npm 11. Follow [the local setup guide](../docs/SETUP.md) from the
repository root: install the root and backend dependencies, start local Supabase,
then run `npm run setup:local`. This generates the ignored `backend/.env`, the
restricted `nene_api` database credential, and Android-emulator app configuration.
It preserves existing configuration by refusing to overwrite it. No hosted service
or paid plan is provisioned by these files.

The `.env.example` file documents manual configuration when needed. Its required
values are deliberately incomplete; the server refuses startup when they are
absent. Keep actual `.env` values private. Once root setup has completed, run from
this folder:

```powershell
npm run start:dev
```

The default API binds to `127.0.0.1`; Android emulator configuration uses
`10.0.2.2` to reach the host. The Flutter app accepts HTTP only for its allowed
local hosts in debug mode. A physical device requires suitable HTTPS service URLs
or an explicit development networking setup; merely changing to a LAN HTTP address
does not work with the current app restrictions. Production hosting remains open.

`npm run build` compiles into `dist/`; `npm start` runs that build. `npm run lint`
checks TypeScript. `npm test` compiles and runs Node's test runner with Nest's test
module and HTTP requests. `npm run check` combines lint, build, and tests.

## API contract

| Method and path                           | Access         | Purpose                                                           |
| ----------------------------------------- | -------------- | ----------------------------------------------------------------- |
| `GET /api/v1/health`                      | Public         | Process liveness only                                             |
| `GET /api/v1/me`                          | Active profile | ID, Auth email, display name, role, nullable phone/address        |
| `GET /api/v1/me/accounts`                 | Customer       | Own stored accounts; money is an integer string                   |
| `PATCH /api/v1/me/contact`                | Customer       | Update own phone/address                                          |
| `POST /api/v1/officer/customers`          | Officer        | Idempotent local demo identity/profile/initial account creation   |
| `GET /api/v1/officer/customers?query=...` | Officer        | Search name/email/phone; blank search returns no rows, maximum 20 |
| `GET /api/v1/officer/customers/:id`       | Officer        | Customer detail and accounts                                      |
| `PATCH /api/v1/officer/customers/:id`     | Officer        | Requested name/phone/address edit with an audit reason            |

See [the full API contract](../docs/API.md) for request fields and status codes.

Health confirms only that the process serves requests. It performs no database or
Supabase check. `/me` verifies the token through Supabase Auth's `getUser(token)`,
then queries `bank.user_profiles` with the verified subject ID. Application roles
come from this table, never editable authentication metadata. All routes are
protected by default; only health opts out. Missing/invalid sessions return 401;
missing/disabled profiles return 403; dependency failures return 503.

The SQL role has narrowly scoped column grants for this flow. Customer creation
cannot choose a role or opening balance. Profile edits cannot modify roles, status,
sign-in email or banking balances. An officer profile must still be provisioned
through a trusted local development procedure; there is no officer creation or
public signup API. Session authentication is not eKYC or transaction-bound 2FA.

## Provisioning and retry behavior

Creation requires a UUID `Idempotency-Key` and the same original payload on retry,
including the initial password. The server commits a request row with reserved
customer/account UUIDs before contacting Auth. A salted scrypt fingerprint checks
payload equality without persisting plaintext credentials. A bounded row lock
serializes a request; Auth lookup reconciles the reserved identity after a crash or
timeout. Profile, initial account and request completion commit together. An
uncertain result never causes automatic deletion or a replacement identity.

The initial password is supplied for the synthetic demo, not sent by email or
returned in the API response. Existing unrelated sign-in identities are never
adopted. The local adapter explicitly confirms the email for demo activation; this
does not establish email ownership or eKYC. Creation returns 503 without a backend
secret, in production, or with a non-loopback Auth URL. Hosted activation and
password recovery remain separate work. A caller must retain the request key and
original payload to recover a pending creation; plaintext passwords are held only
in request memory. There is no background creation worker or request-expiry cleanup.

## Configuration and data boundary

- `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` configure session validation.
  Optional `SUPABASE_SECRET_KEY` enables the local demo Auth administrator adapter.
  Existing reads and login work without it. Keep this value on the backend only.
- `DATABASE_URL` must use `nene_api` (or the Supabase pooler form
  `nene_api.<project-ref>`). Never connect the running API as `postgres`.
  Put credentials, host, and port in the URL authority and URI-encode reserved
  password characters. Query parameters are rejected because node-postgres can
  use them to override the validated role, host, or explicit connection options.
- `DATABASE_SSL_MODE=disable` is accepted only for loopback development.
  Hosted connections use `verify-full`, which retains certificate verification.
  If needed, set `DATABASE_SSL_CA_FILE` to the provider CA PEM. Configure TLS
  through these environment variables instead of URL parameters.
- Banking tables are accessed through NestJS, not the client-facing Supabase data
  API. Database credentials never belong in Flutter. Private identity-file APIs
  are not implemented yet.
- The pool is bounded to five connections with connection/query timeouts. The
  transaction helper rolls back local writes on failure and uses a three-second
  lock timeout and twenty-second idle transaction timeout. Auth calls have a
  five-second timeout. No ORM or extra backend is introduced.

Tests use synthetic identities and mocked dependencies. They verify default
protection, malformed/invalid tokens, profile restrictions, trusted roles,
parameterized subject lookup, service failure handling, TLS configuration, strict
input validation, own-contact/account access, duplicate requests, concurrent
retries, payload conflicts and recovery after Auth/database failures.
They do not establish that a live Supabase project or payment integration works.

Versions are pinned in `package.json` and `package-lock.json`. TypeScript 6.0.3 is
used because the selected TypeScript ESLint release supports versions below 6.1.
The ordinary `pg` driver keeps SQL and future transaction boundaries explicit.

## Implementation references

- [NestJS setup](https://docs.nestjs.com/first-steps)
- [Supabase server-validated identity](https://supabase.com/docs/reference/javascript/auth-getuser)
- [node-postgres TLS configuration](https://node-postgres.com/features/ssl)
