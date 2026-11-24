# Hosted sandbox demo

Added 24 November 2026 so the Google Play build (TR-04) can reach a real backend. Until now every money flow ran only against local loopback Supabase; a hosted API refused to enable them.

## What the switch does

`DEMO_DEPLOYMENT=hosted-sandbox` is an exact, opt-in marker read by [environment.ts](../backend/src/config/environment.ts). It requires `NODE_ENV=production`, which already forces HTTPS Auth and verified PostgreSQL TLS. With the marker, these features may run on the hosted API:

| Feature | Still required |
| --- | --- |
| Same-bank, cash and fictional other-bank operations | Its own `*_ENABLED=true` flag **and** its database setting, enabled only by the seed below |
| VNPay checkout, bills, phone, movie tickets | `VNPAY_SANDBOX_ENABLED=true`, sandbox terminal, secret and public return URL |
| Officer creates demo customers / demo accounts | `SUPABASE_SECRET_KEY` on the API; officer role |
| Walking route | Public FOSSGIS Valhalla instance, existing per-instance rate limit |

Unchanged everywhere: synthetic data only, sandbox provider only, transaction-bound TOTP on every money movement, the 5,000,000 VND limit, no public signup and no client-selected roles. Without the marker, hosted enablement still fails closed (see `environment.spec.ts`).

## Shape

Android app → `https://<render-service>.onrender.com/api/v1` (NestJS on Render) → Supabase cloud (Auth, PostgreSQL through the session pooler, private Storage). VNPay sandbox calls back to the same Render host. Supabase's Data API is disabled; banking tables are reachable only through NestJS.

## Setup checklist

Never paste passwords or keys into chat, commits or screenshots.

1. **Supabase project:** Free plan, region Southeast Asia (Singapore), **Data API disabled**. Save the generated database password privately; only migrations need it.
2. **Migrations** (your own terminal, from the repo root):
   ```powershell
   npx supabase login
   npx supabase link --project-ref <project-ref> --workdir infrastructure
   npx supabase db push --workdir infrastructure --dry-run
   npx supabase db push --workdir infrastructure
   ```
   `link` asks for the database password. `db push` only applies `infrastructure/supabase/migrations`; it does not push `config.toml`.
3. **Restricted API role** (Dashboard → SQL Editor). Generate a new letters-and-digits password, different from the database password:
   ```sql
   alter role nene_api login password '<new-nene-api-password>';
   ```
4. **Auth settings** (Dashboard → Authentication), matching `infrastructure/supabase/config.toml`:
   - Disable "Allow new users to sign up". Keep the email provider on.
   - Minimum password length 12.
   - Multi-factor: TOTP enabled (default). If recovery-code settings exist, enable them; otherwise backup-code recovery is unavailable in the hosted demo. Authenticator setup and transaction codes do not depend on it.
5. **First officer:** Authentication → Users → Add user (synthetic `@example.invalid` email, auto-confirm). Copy its UUID, then in the SQL Editor:
   ```sql
   insert into bank.user_profiles (id, display_name, role, email)
   values ('<auth-user-uuid>', 'Demo officer', 'officer', '<officer-email>');
   ```
6. **Render web service:** connect the GitHub repo, root directory `backend`, build `npm ci --include=dev && npm run build` (with `NODE_ENV=production`, plain `npm ci` skips the TypeScript compiler), start `npm start`, health check `/api/v1/health`. Set variables from [hosted.env.example](../backend/hosted.env.example). Supabase's public root CA ships as [backend/certs/supabase-root-2021.crt](../backend/certs/supabase-root-2021.crt) (`CN=Supabase Root 2021 CA`, valid to 2031); `DATABASE_SSL_CA_FILE=certs/supabase-root-2021.crt` resolves from Render's `backend` root. `DATABASE_URL` comes from Dashboard → Connect → **Session pooler**, with the user changed from `postgres.<ref>` to `nene_api.<ref>`.
7. **Demo customers and funds:** sign in to the app as the officer and create two customers with `@example.invalid` emails. Then print the seed SQL locally and run it in the SQL Editor:
   ```powershell
   node scripts/hosted-seed-sql.mjs <source-account> <recipient-account>
   ```
   The source receives a one-time 3,000,000 VND synthetic opening fixture plus a simulated cash source, and the transfer, cash and other-bank settings are enabled. The seed refuses to reset or top up an account.
8. **VNPay (optional until credentials arrive):** register the sandbox with return URL `https://<render-service>.onrender.com/api/v1/payments/vnpay/return` and IPN URL `https://<render-service>.onrender.com/api/v1/payments/vnpay/ipn`, then set the `VNPAY_*` variables and redeploy.

## Known limits and unverified points

- Verified 24 Nov: backend lint/build, 168 unit/HTTP tests and the seed SQL printer. All 16 migrations, including the restrictive storage policies, applied to the hosted project, and local/remote history match. Pooler TLS fails with Node's default CA store (`SELF_SIGNED_CERT_IN_CHAIN`) and passes `verify-full` with the bundled Supabase root CA.
- To confirm on first deploy: the Render service itself, and recovery-code availability.
- Render free instances sleep after inactivity; the first request can take about a minute. Supabase free projects pause after about a week without activity, so keep them active through grading.
- VNPay `vnp_IpAddr` records Render's proxy address rather than the phone's address. This is informational in the sandbox.
- The interbank, cash and transfer flows are simulations; the hosted marker does not turn them into real banking services.
