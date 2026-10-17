# Nene API foundation

This is the single NestJS backend selected for Nene. It establishes configuration,
session verification, and a read-only application profile boundary supporting
BR-01/BR-03 and TR-03. It does not complete those requirements: customer creation,
profile editing, eKYC, financial accounts, transaction 2FA, payments, utilities,
navigation, and chatbot behavior remain to be implemented under [SCOPE.md](../SCOPE.md).

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

| Method and path      | Access                                     | Response                                                                                           |
| -------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `GET /api/v1/health` | Public                                     | `{ "status": "ok", "service": "nene-api", "check": "liveness" }`                                   |
| `GET /api/v1/me`     | Verified bearer session and active profile | `{ "id": "uuid", "email": "email or null", "displayName": "name", "role": "customer or officer" }` |

Health confirms only that the process serves requests. It performs no database or
Supabase check. `/me` verifies the token through Supabase Auth's `getUser(token)`,
then queries `bank.user_profiles` with the verified subject ID. Application roles
come from this table, never editable authentication metadata. All routes are
protected by default; only health opts out. Missing/invalid sessions return 401;
missing/disabled profiles return 403; dependency failures return 503.

The SQL role has SELECT access only. Profiles must be provisioned through the
trusted local development procedure; this base does not expose account creation
or role changes. Future officer operations need explicit permissions. Session
authentication is not eKYC or transaction-bound 2FA.

## Configuration and data boundary

- `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` configure Auth validation only.
  The backend currently needs no Supabase secret/service-role key.
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
- The pool is bounded to five connections with connection/query timeouts. No
  transaction-writing abstraction, ORM, or extra backend deployment is introduced
  before an actual financial flow needs it.

Tests use synthetic identities and mocked dependencies. They verify default
protection, malformed/invalid tokens, profile restrictions, trusted roles,
parameterized subject lookup, service failure handling, and TLS configuration.
They do not establish that a live Supabase project or payment integration works.

Versions are pinned in `package.json` and `package-lock.json`. TypeScript 6.0.3 is
used because the selected TypeScript ESLint release supports versions below 6.1.
The ordinary `pg` driver keeps SQL and future transaction boundaries explicit.

## Implementation references

- [NestJS setup](https://docs.nestjs.com/first-steps)
- [Supabase server-validated identity](https://supabase.com/docs/reference/javascript/auth-getuser)
- [node-postgres TLS configuration](https://node-postgres.com/features/ssl)
