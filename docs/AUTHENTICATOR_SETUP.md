# Authenticator setup and status

Implemented 3 November 2026 as BR-04 support. This first-time enrollment slice does not complete transaction-bound 2FA or eKYC. AWS remains undecided. No financial operation is enabled.

Customers open **My profile → Transaction security**, within five minutes of password sign-in, and add the displayed private manual key to a time-based authenticator account named Nene. They enter its six-digit code. The app shows **Authenticator ready** only after backend/provider confirmation. Manual entry supports using an authenticator on the same phone; QR rendering is not included in this slice. Setup secrets and entered codes are memory-only, hidden while backgrounded, and cleared on success/disposal. Browser reload requires sign-in.

NestJS exposes customer-only `GET /api/v1/me/security`, `POST /api/v1/me/security/setup` and `POST /api/v1/me/security/verify`. Responses use `Cache-Control: no-store`. Verify accepts only `requestId` and `code`; the factor, owner and originating Auth session come from server records. Setup requires fresh signed password timing after SessionGuard validates the exact token through Auth. One durable reservation per customer prevents concurrent/duplicate enrollment. Records retain only IDs, state, revision, attempt count and timestamps, never the setup key, code or session pair.

The pending request expires after ten minutes. Atomic reservation permits one verification at a time and at most five attempts. Only definite no-rotation rejections permit retry within limits. Unknown provider/database outcomes stay restricted; status reconciles a verified factor after a lost response without replaying tokens. A lost initial setup key, expired request, different session during pending setup or unknown enrollment shows help rather than silently creating or deleting factors. [Authenticator management](AUTHENTICATOR_MANAGEMENT.md) now supports replacement/recovery after completed setup; it does not add initial-enrollment cancellation/reset. Synthetic fixture maintenance is not a customer reset feature.

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

Follow-up [management implementation and evidence](AUTHENTICATOR_MANAGEMENT.md) adds shared setup/lifecycle proof reservations, replacement and native backup-code recovery with conservative interruption handling. Active-factor/security-revision admission and shared proof reservation at financial consumption remain unimplemented. Setup verification must never be reused as payment approval. No hosted project, paid provider, AWS service or real customer identity was used. The shared policy directory was unavailable.
