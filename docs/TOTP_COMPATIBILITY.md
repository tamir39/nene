# Supabase TOTP compatibility experiment

Date: **27 October 2026**. Supports the BR-04 transaction-2FA design in [TRANSACTION_FLOW.md](TRANSACTION_FLOW.md); this is test evidence, not a completed financial feature or a lecturer-approved exception. AWS and the face-comparison method remain undecided.

**Result: enrollment and code verification work, but Supabase MFA alone does not meet Nene's transaction-authorization rules.** A successful code was accepted on another challenge. Two simultaneous requests also both verified the same challenge. Do not enable financial posting or treat an `aal2` session as permission to execute a payment.

Supabase remains a possible factor verifier. Selection is deferred until a small backend authorization adapter proves operation binding, replay prevention and recovery. This result does not require changing Flutter, NestJS or Supabase, adding another provider, or selecting AWS.

Follow-up: the [backend safeguards prototype](AUTHORIZATION_PROTOTYPE.md) subsequently passed 24 isolated checks, including real Supabase verification through shared PostgreSQL reservations. It is unregistered and moves no money. The observations below remain the provider-only findings; app integration, factor choice and customer recovery/session handoff are still open.

## What ran

- The exact cached Auth image used by the running Nene stack: `public.ecr.aws/supabase/gotrue:v2.197.0`, image ID `sha256:1736a63078f5922b198c4cbe50f80ab9a2d3b54fe8b7b6cfb2e9dc5dbbc12c6b`.
- Installed JavaScript SDK `@supabase/supabase-js` / `auth-js` **2.117.3**, with separate memory-only clients for two users. A local fetch adapter removed the gateway's `/auth/v1` prefix because the experiment connected directly to GoTrue.
- An isolated disposable `postgres:16-alpine` database, image ID `sha256:4e6e670bb069649261c9c18031f0aded7bb249a5b6664ddec29c013a89310d50`. This is not Nene's PostgreSQL 17 banking database and contains no banking schema or balances.
- Fresh random credentials and synthetic `@example.invalid` users; a test-only authenticator generated codes in memory. No real person's factor, face, phone or email was used. The helper passes all six RFC 6238 SHA-1 vectors, including six-digit projections, plus malformed-input and time-boundary checks: **5 tests passed**.
- A dedicated temporary Docker network, unpublished database, tmpfs database data, and Auth explicitly bound to `127.0.0.1:3001`. The runner only considers free ports 3001–3005 and never stops another listener. No images are pulled automatically. Runtime logs are disabled; output contains status/error codes and safe observations, not credentials, QR secrets or OTPs.
- TOTP was enabled only inside the temporary Auth container. Public signup stayed disabled. Refresh rotation was enabled with a 10-second reuse interval. The fixture's MFA challenge/verify limit was raised to 200 so this probe would not confuse throttling with replay rejection; production attempt limits were not tested.

The normal Nene Auth configuration, existing demo accounts, database, services and local-only runner files were not changed. The completed run recorded 24 observations before its cleanup result and exited successfully. This means the experiment completed; it does **not** mean the transaction security criteria passed.

## Observed results

| Probe | Observed result | Meaning for Nene |
| --- | --- | --- |
| Public signup / anonymous enrollment | `422 signup_disabled` / `401 no_authorization`. | Synthetic users require fixture administration; no public signup was added. |
| Wrong and five-minute-old code | Both `422 mfa_verification_failed`. | Invalid proof rejected in this configuration. Fixtures exclude accidental collisions with currently valid codes. |
| Another user verifies or challenges the factor | Both `404 mfa_factor_not_found`. | Provider factor ownership enforced for these requests. |
| Valid enrollment proof | `200`; returned session usable at `aal2`, same session ID, changed refresh token. | Factor verification works; this contains no payment authorization. |
| Original access token after verification | `/user` still returned `200`. | Verification does not immediately make the earlier access token unusable. |
| Same successful challenge, sequential retry | `422 mfa_ip_address_mismatch`. | Already-verified challenges are rejected sequentially. The error name also covers this case; it does not prove an IP change. |
| Same successful code, fresh challenge | `200`. | Successful-code consumption is not enforced across challenges in this runtime. |
| Two concurrent challenge creations | One `200`, one `500 unexpected_failure`. | A provider error is uncertainty, not proof of replay prevention. The underlying server error was not diagnosed. |
| Same code, two different challenges verified concurrently | Both `200`. | Separate challenge IDs do not stop reuse of one successful code. |
| Two simultaneous verifies of one challenge | Both `200`. | Sequential replay rejection does not guarantee single consumption under concurrency. This is a sampled pair, not a stress-test result. |
| Deliberately different forwarded IP | `422 mfa_ip_address_mismatch`; the matching IP then succeeded. | Challenge and verification must use a consistent backend path. This does not validate the app proxy's trust configuration. |
| Expired challenge | `422 mfa_challenge_expired`. | Only the disposable fixture's `created_at` was aged by ten minutes. No production clock/config was changed. |
| Discard a known successful reply, then retry that challenge | `422 mfa_ip_address_mismatch`; no transaction receipt exists. | Repeating verify cannot reconstruct a missing operation authorization result. This simulated response loss does not test network faults or durable database recovery. |
| Installed SDK verification, separate users and returned-session refresh | All succeeded; users stayed isolated and refreshed session kept its ID and `aal2`. | Request-scoped SDK use is viable at the provider boundary. NestJS/Flutter integration is still unimplemented. |
| Removed factor | Challenge returned `404 mfa_factor_not_found`. | Removed factor cannot create a fresh challenge. |
| Original pre-MFA refresh token immediately after verification, separate fixture | `200`, returning `aal2`; subsequently refreshing the returned token also succeeded. | This is immediate behavior with the tested token format/configuration and reuse interval. It is not a general recovery guarantee or proof of transaction completion. |

The [official verify contract](https://supabase.com/docs/reference/javascript/auth-mfa-verify) takes factor ID, challenge ID and code, not amount, recipient or operation version. The [pinned MFA implementation](https://github.com/supabase/auth/blob/v2.197.0/internal/api/mfa.go) explains why an already-verified challenge and an IP mismatch share an error identifier. The [pinned token implementation](https://github.com/supabase/auth/blob/v2.197.0/internal/api/token.go) also shows why session/refresh behavior needs runtime testing instead of relying on a login assurance level. These sources explain the observations; they do not establish untested hosted behavior.

## Smallest next step

Keep the factor choice provisional. The following adapter goals were subsequently exercised by [AUTHORIZATION_PROTOTYPE.md](AUTHORIZATION_PROTOTYPE.md); their production integration is still required before implementing a transfer:

1. Bind a server-created attempt to one immutable reviewed operation/version, customer and factor. Recheck current roles, account eligibility and identity prerequisites before posting.
2. Serialize attempts and reserve a bounded, protected proof fingerprint before provider verification so simultaneous requests cannot reuse a code across operations. A plain hash of a six-digit code is insufficient. Define retention against the provider's acceptance window; multiple API processes must share the enforcement. Do not store authenticator secrets or raw codes in application records.
3. Record only a server-observed result for that attempt. A timeout or ambiguous provider failure must never authorize money movement. Define safe session handoff and supersede uncertain attempts before accepting fresh proof; a provider login result alone cannot recover a transaction receipt.
4. Consume authorization exactly once with the eventual local debit, credit and history in one database transaction. Test changed details, ownership, attempt caps, concurrent requests, crashes and retry recovery. A direct call to Supabase Auth must not set a Nene authorization record.

These are not protections enabled in the running app. The interpretation of durable pre-authorization records, high-value threshold, actual face comparison, funding/account rules and factor recovery remain open. The follow-up prototype demonstrates feasibility within its stated limits; do not quietly weaken the planned rules or add extra services when integrating it.

## Reproduce and cleanup

On Windows with Docker Desktop running and the two listed images already cached, install the repository's locked root/backend dependencies, then run from the repository root:

```powershell
node --test scripts/totp-fixture.test.mjs
node scripts/check-totp-compatibility.mjs
```

The [runner](../scripts/check-totp-compatibility.mjs) needs access to the local Docker Desktop engine; it does not need Nene's `.env` files or `run.bat`. It refuses to pull images, uses fresh labelled resources, and removes only matching owned containers/network by ID in `finally`. Container removal deletes the disposable data. If force-killed before cleanup, identify the printed/labelled `nene-totp-check-<run-id>` resources, verify their `dev.nene.totp-check` label, and remove only that experiment's resources; never remove normal `nene-local` containers or volumes to clean up this test.

All temporary containers and networks were confirmed absent after the run; port 3001 had no listener. Existing Nene and unrelated containers were left as found. Early fixture attempts were cleaned up too: Docker withheld publication on an internal network, and database schema/readiness setup needed correction before the completed run.

No Edge, Android Studio or emulator was launched. A human authenticator/phone journey, NestJS endpoints, Flutter UI, hosted Supabase, production limits/recovery, financial posting and BR-04 acceptance are **not verified**. The original assessment PDF and rubric remain unchanged. The shared policy directory was unavailable; no compliance with unseen policies is claimed.
