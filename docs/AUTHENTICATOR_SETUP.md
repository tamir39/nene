# Authenticator setup and status

Implemented 3 November 2026 as BR-04 support. This first-time enrollment slice does not complete transaction-bound 2FA or eKYC. AWS remains undecided. No financial operation is enabled.

Customers open **My profile → Transaction security**, within five minutes of password sign-in, and add the displayed private manual key to a time-based authenticator account named Nene. They enter its six-digit code. The app shows **Authenticator ready** only after backend/provider confirmation. Manual entry supports using an authenticator on the same phone; QR rendering is not included in this slice. Since app 1.0.3, Android phones can instead keep the key in the app as [Nene Smart OTP](SMART_OTP.md), unlocked by fingerprint or screen lock; the endpoints below are unchanged. Setup secrets and entered codes are memory-only, hidden while backgrounded, and cleared on success/disposal. Browser reload requires sign-in.

NestJS exposes customer-only `GET /api/v1/me/security`, `POST /api/v1/me/security/setup` and `POST /api/v1/me/security/verify`. Responses use `Cache-Control: no-store`. Verify accepts only `requestId` and `code`; the factor, owner and originating Auth session come from server records. Setup requires fresh signed password timing after SessionGuard validates the exact token through Auth. One durable reservation per customer prevents concurrent/duplicate enrollment. Records retain only IDs, state, revision, attempt count and timestamps, never the setup key, code or session pair.

The pending request expires after ten minutes. Atomic reservation permits one verification at a time and at most five attempts. Only definite no-rotation rejections permit retry within limits. Unknown provider/database outcomes stay restricted; status reconciles a verified factor after a lost response without replaying tokens. A setup that was **never verified** can be restarted once it is abandoned, as described below; nothing that protects a verified authenticator changed. [Authenticator management](AUTHENTICATOR_MANAGEMENT.md) supports replacement/recovery after completed setup. Synthetic fixture maintenance is not a customer reset feature.

## Restarting an abandoned initial setup

Added 26 November 2026. Before this change, one durable setup row per customer meant that closing the app, changing session or waiting ten minutes before verifying left status `blocked` permanently: `POST /setup` refused the existing row or the leftover unverified provider factor, and the app had no next step.

**Abandoned initial setup.** All of these must hold:

- Auth `GET /user` lists **no verified factor** of any type for the customer.
- The Nene row is `starting`, `pending`, `verifying` or `blocked`, never `ready` or `restricted`. A replacement or recovery flow always marks the row `restricted` and keeps a verified factor, so it is excluded twice.
- Either the row has expired by the database clock (`expires_at <= now()`), or it belongs to a different Auth session **and** is `starting` or `pending` with fewer than five attempts.

A setup blocked by five wrong codes therefore stays blocked until it expires, even after a new sign-in. A `verifying` row, whose verification might still be running, also waits for expiry. A setup in the same session before expiry stays `pending` (or `blocked` if this screen has lost its key), so a double tap cannot race itself.

**Status.** `GET /me/security` returns `{state: "not_set_up"}` for an abandoned setup, so the installed app shows its normal **Set up authenticator** button. Other states are unchanged. Expiry for `pending` now uses the database clock, consistent with verification.

**`POST /me/security/setup` sequence for an existing row.**

1. Fresh password evidence (at most five minutes old) is checked first, as before.
2. Read the row and the provider factors. If any factor is verified, refuse with 409 "Existing factors require recovery support." and change nothing. If the row is not abandoned, 409 "Setup already exists. Check status."
3. Claim the row with one guarded `UPDATE … where customer_id, request_id and state still equal the values just read`. The same statement repeats the abandonment conditions with `now()`. It sets a new request ID, the caller's session, `state='starting'`, `factor_id=null`, `attempts=0`, `revision=revision+1`, and new `expires_at` (ten minutes) and `created_at`. Zero updated rows means a concurrent start won: 409 "Check setup status." No row is deleted; `nene_api` still has no `DELETE` on this table and no migration or grant was added.
4. Read the factors again. If a verification finished in between, the claim is restored to the previous values and the request is refused with 409.
5. Remove **only unverified TOTP** factors with the customer's own AAL1 token (`DELETE /factors/{id}`, `mfa.unenroll`), then enroll as before. The key is returned once with the new `requestId` and `revision` only after the guarded bind to `pending` succeeds. A superseded request gets 409 and no key.

Any provider or database failure after step 3 leaves a `starting` row owned by the caller's session. It becomes abandoned again after expiry or a new sign-in, so the customer can retry. Records still hold only IDs, state, revision, attempt count and timestamps. Errors use the existing fixed messages, with no key, code or token.

**Provider evidence.** Supabase documents that "a user has to have an `aal2` authenticator level in order to unenroll a `verified` factor" ([mfa.unenroll](https://supabase.com/docs/reference/javascript/auth-mfa-unenroll)). The pinned Auth source requires AAL2 only when `factor.IsVerified()` ([`UnenrollFactor`, v2.197.0](https://raw.githubusercontent.com/supabase/auth/v2.197.0/internal/api/mfa.go)). The same file returns 403 "AAL2 required to enroll a new factor" when a verified factor exists, and rejects a duplicate friendly name. The new local check below confirmed the AAL1 removal on Auth v2.197.0 and v2.198.0 (the local stack's version). The hosted Auth version was not tested. If a project enables Auth's factor-unenrolled notification email, removing the unverified factor may send one.

**App copy.** The screen now says **Setup paused** for `blocked`, or for `pending` after it lost its key: "Too many attempts, or the setup was interrupted. Wait up to 10 minutes, then tap Check status to start again." `restricted` keeps "Continue an existing security change below." This copy ships in the next Play build; the server-side restart already works with the installed app.

**Still blocked.** A lost **verified** authenticator plus all recovery codes, a `ready` row whose factor disappeared outside Nene, and any setup where Auth lists a verified factor that Nene did not bind. These need synthetic-demo investigation; there is no password-only or officer reset.

The app now uses the tested memory-only SessionOwner instead of a mutable SDK session. All refresh/verification rotation is serialized, and logout invalidates old work immediately. A definite no-rotation rejection retains the session for a corrected code; uncertainty clears it. The app calls the configured Auth gateway with explicit credentials and revalidates the backend profile on adoption. Each browser tab signs in independently. AppConfig retains release HTTPS and the narrow local debug exceptions. Ordinary background refresh runs through the same owner.

## Local testing

TOTP enrollment/verification are enabled in the Supabase configuration; phone MFA and public signup remain disabled. Restart the Nene local stack after changing flags. `run.bat` applies forward migrations and builds the backend; keep it local and uncommitted. If old Nene containers were already running, stop Nene with `run.bat stop` before restarting so changed Auth flags are applied. Never delete database volumes to refresh configuration.

1. Start `run.bat` and open its desktop URL in Edge.
2. Sign in as a synthetic customer, then immediately open Transaction security.
3. Add the manual key to a time-based authenticator and submit its code.
4. Confirm **Authenticator ready**, then sign out/in and check status again.
5. On a separate fresh synthetic customer, try a wrong code followed by a correct one. Officers must not see the setup entry or access the endpoints.

Do not send setup keys, codes or secret-bearing screenshots to the chat or commit them. Payments remain unavailable. Native Android acceptance, a real human authenticator and full Edge-to-NestJS acceptance are still pending user-started demo testing.

## Automated evidence

- Backend lint/build and all 79 tests passed; format check passed.
- Debug web compilation with the existing local browser config passed; no demo was launched. Nene Supabase was stopped with backup enabled to apply changed MFA flags on the next user launch.
- Existing Flutter suite: 167 tests passed. Two additional tests pass for narrow-screen manual enrollment, secret clearing and explicit rejected-code retry. Flutter analysis passed.
- `node scripts/check-authenticator-setup.mjs`: 12 real local Auth/PostgreSQL checks passed using disposable synthetic fixtures, including session ownership, wrong-code retry, durable status, duplicate rejection and lost-reply reconciliation. Fixture cleanup completed. This invokes the service with validated fixture tokens; it does not claim full browser/HTTP acceptance.
- The existing fixture owner tests now exercise the production owner through a re-export. Other prior SDK/provider experiments retain their historical limits.
- Restart, 26 November 2026: backend lint, build and all 201 tests passed, including 13 new restart tests with fake rows and provider (no network). Backend formatting passed. Flutter analysis passed and all 345 tests passed, including the paused and restricted copy. `node scripts/check-authenticator-setup.mjs` now runs 21 checks; all passed on the isolated Auth v2.197.0 fixture, and again on a temporary copy using the cached v2.198.0 image. The run covered a new-session restart, AAL1 removal of only the unverified factor, the old request being refused, the attempt limit holding until a simulated expiry, the restarted setup verifying to AAL2, and a verified factor refusing a restart with the row unchanged. Synthetic users lived only in the disposable fixture, which was removed afterwards. No hosted project was touched; the real stuck hosted customer is not yet confirmed fixed.

Follow-up [management implementation and evidence](AUTHENTICATOR_MANAGEMENT.md) adds shared setup/lifecycle proof reservations, replacement and native backup-code recovery with conservative interruption handling. Active-factor/security-revision admission and shared proof reservation at financial consumption remain unimplemented. Setup verification must never be reused as payment approval. No hosted project, paid provider, AWS service or real customer identity was used. The shared policy directory was unavailable.
