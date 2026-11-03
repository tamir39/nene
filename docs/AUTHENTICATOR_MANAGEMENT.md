# Authenticator replacement and recovery

Implemented 3 November 2026 as **BR-04 support** after [first enrollment](AUTHENTICATOR_SETUP.md). PDF page 2, Business 2 requires transaction 2FA; the PDF does not prescribe this recovery mechanism. Provider-native backup codes and the limits below are Nene engineering decisions. AWS remains undecided. No payment, financial authorization, identity match, password reset or officer MFA reset is added.

## Customer flow

Open **My profile → Transaction security → Manage authenticator and recovery** within five minutes of password sign-in. An existing registered, verified authenticator is required.

| Action | Proof and outcome |
| --- | --- |
| Create / replace recovery codes | A fresh current-authenticator code authorizes generation. The customer explicitly acknowledges replacing any old set, saves the once-displayed codes, then finishes and signs out everywhere. |
| Replace authenticator | Prove the current authenticator, add the new private manual key, verify the replacement, then submit another fresh new-authenticator code to retire the old factor and replace backup codes. Save the codes and finish. |
| Use a recovery code | Password sign-in plus one saved unused recovery code permits replacement only. Enroll and verify a new authenticator, generate a new backup set, save it and finish. The consumed code cannot be reused; the previous backup set is invalidated. |
| Lost authenticator and all backup codes | Blocked. Password alone, an officer edit, or reference acceptance cannot reset the factor. No fallback account-unlock workflow is implemented. |

The old authenticator remains registered until the new one is verified. Issuance displays plaintext codes once; status exposes only the remaining count. There is no download, logging, persistence or retrieval of codes in Nene. The tested local provider generates ten codes. Keep them privately outside the app and never send keys, codes or secret-bearing screenshots to chat.

The Flutter screen uses the existing lighter Open pocket theme and memory-only SessionOwner. Auth mutations and non-rotating security requests share the refresh queue. Responses are discarded after logout or account change; a handoff must match its request, purpose, customer, Auth session and revision before exposing codes. Secrets are hidden in the background, entered codes cleared, and displayed material cleared on expiry, uncertainty, completion or disposal. Browser reload loses the display and requires sign-in.

## Backend rules

- SessionGuard verifies the exact bearer with Auth and loads the active application profile. Customer-only service checks deny officers, even when they know a request ID. Bodies cannot supply customer, factor or revision values.
- Signed password AMR timing must be at most five minutes old for starting, explicit resume and cancellation; token refresh or AAL2 alone is insufficient. Starts after a completed/cancelled change require password evidence newer than that security change.
- One active durable management request per customer. Starting immediately marks the registered binding `restricted` and advances its security revision. The ten-minute request belongs to one Auth session. Safe resume requires fresh password plus fresh appropriate factor/recovery proof, rebinds the session, and advances revision again.
- State reservations and per-command lease IDs prevent concurrent commands and late completions from silently restoring readiness. New-factor verification and old-factor deletion are separate, checked steps. Finalization verifies the active factor, old-factor retirement and a nonempty backup set, globally revokes Auth sessions, then atomically marks the binding ready and the request complete. The client clears local ownership and requires clean sign-in.
- Setup and management share a database-serialized proof reservation. A keyed HMAC stores an attempted-code fingerprint, scoped to customer and factor; no raw proof is stored. Reusing an attempted code across these purposes is rejected. Up to ten distinct attempts per customer in a rolling fifteen-minute window, including successful attempts. Proof/new-factor verification is also capped at five attempts per management request. These are provisional engineering limits, not PDF rules; provider throttles can impose further limits.
- Client-facing database roles cannot read or write lifecycle records or the private HMAC key. API privileges do not include financial writes. Provider backup-code hashing/consumption remains Supabase's responsibility.

[Transaction confirmation preview](TRANSACTION_CONFIRMATION.md) now joins the same proof reservation and rechecks the active binding/revision before recording a detail-bound authenticator check. Future financial authorization **must** also enforce these at final consumption, alongside identity/funds checks and atomic posting. The older unregistered authorization prototype is still separate. Setup, recovery codes, recovery AAL2, security management and the not-sent preview never authorize money movement.

## Interruptions and current limits

| Situation | Supported behavior |
| --- | --- |
| Definite wrong code or Nene replay/rate rejection | Retain the session and permit a corrected, unused proof within limits. No automatic retry. |
| Different session or expired request in a safe phase | Fresh password sign-in and explicit fresh proof are required. Before new-factor verification, recovery uses another unused backup code. After verification, only the new authenticator may resume. |
| New-factor verification happened but its response was lost | Status inspects the owned provider factor; fresh new-authenticator proof can resume. It does not replay the earlier token pair or declare ready. |
| Backup display lost after confirmed issuance | Fresh proof, explicit acknowledgement and deliberate generation of another set. The previous plaintext is not retrieved. |
| Unverified replacement abandoned/lost its setup key | Fresh password cancellation removes only the owned unverified replacement after confirming the old verified factor remains. It never deletes a verified replacement. The customer signs out and starts again. |
| Final global-sign-out reply or database commit uncertain | Remain restricted. Fresh sign-in can retry final cleanup; no financial proof is created. |
| Unknown proof, enrollment or issuance outcome (`proving`, `enrolling`, `issuing`), exhausted request attempts or unexpected factor inventory | Remain restricted; no blind provider retry or password-only reset. Synthetic-demo investigation is needed if status stays unresolved. Automatic reconciliation for these cases is not implemented. |

Initial enrollment with a lost key remains subject to the older setup restrictions. Cancellation is for unverified replacement, not a universal MFA reset. Hosted recovery configuration, notification/alert policy, real-user support procedures, native acceptance and human end-to-end acceptance are still open. Do not present this coursework slice as a production-complete recovery system.

## Implemented API

Base `/api/v1/me/security/management`, customer-owned and `Cache-Control: no-store`:

| Method/path | Exact input | Result |
| --- | --- | --- |
| `GET /` | None | `{remaining, management}`; metadata only, or `management: null`. |
| `POST /start` | `{purpose: "codes" | "replace" | "recover"}` | Request ID, revision, purpose and initial step. |
| `POST /prove` | `{requestId, code}` | Current-factor/recovery proof; validated session pair and binding. |
| `POST /resume` | `{requestId, code}` | Explicit safe-phase reproof; pair bound to the pre-command revision, then status reports the incremented revision. |
| `POST /enroll` | `{requestId}` | Once-returned replacement key plus request ID/revision. |
| `POST /verify` | `{requestId, code}` | New-factor verification; session pair and binding. |
| `POST /issue-codes` | `{requestId, code}` | Fresh active-factor proof, retirement/rotation, session pair and once-displayed codes. |
| `POST /finish` | `{requestId, saved: true}` | `{signedOut: true}` after final revocation/commit. |
| `POST /cancel` | `{requestId}` | `{cancelled: true}` only for the unverified replacement phases; client signs out. |

Proof replies carry `requestId`, `revision`, `purpose`, `accessToken`, `refreshToken`. Purposes are `manage-proof`, `manage-resume`, `manage-new`, `manage-issue`. Management metadata includes step, expiry, same-session/expired flags, resumability and required proof kind. Those flags guide the screen, not authorization. `400` is invalid input/definite rejected proof, `429` the Nene rolling limit, `401/403` authentication/role/freshness denial, `409` ownership/state conflict, and `503` uncertainty/unavailable provider. Do not retry an uncertain mutation automatically.

## Verification and local demo

The isolated fixture uses real GoTrue v2.197.0 and PostgreSQL with synthetic users, native recovery enabled, restricted `nene_api` credentials and automatic cleanup:

```powershell
npm --prefix backend run check
npm --prefix backend run format:check
node scripts/check-authenticator-management.mjs
node scripts/check-authenticator-setup.mjs
```

From `app/`, run `flutter analyze --no-pub` and `flutter test --no-pub`. Optional `flutter test --no-pub --dart-define=CAPTURE_SECURITY_UI=true test/security_management_test.dart` renders the secret-free overview into ignored `.tmp/security-ui/management.png` for visual review. This is widget evidence, not a live browser check.

Verification on 3 November: 95 backend tests and 186 Flutter tests passed; backend formatting, Flutter analysis and the Edge debug web build passed. The secret-free 390-pixel overview was rendered and visually reviewed. The management fixture passed 20 checks covering concurrent reservation, owner/role denial, cross-purpose replay, wrong-code correction, old-factor preservation/retirement, single-use and rotated codes, global revocation, expiry/resume revisions, lost verification replies, uncertain issuance, secret-free records and client-role denial. All twelve setup fixture checks still pass. Local Docker helper tests pass (8); no normal demo/emulator was launched. Live browser/native acceptance remains for the user-started demo.

For this Windows checkout, the uncommitted launcher helper adds `GOTRUE_MFA_RECOVERY_CODES_ENROLL_ENABLED=true` and `GOTRUE_MFA_RECOVERY_CODES_VERIFY_ENABLED=true` only when creating the owned `supabase_auth_nene-local` container. Existing containers need recreation: **run `run.bat stop`, then `run.bat`**; database volumes are retained. This local runner change is deliberately excluded from Git/PR, as requested. A fresh clone must configure these flags in its own local Auth fixture/launcher; the ordinary pinned CLI configuration alone is not claimed to enable native recovery. No hosted settings were changed.

Test first with a synthetic customer: create and privately save codes; sign in again; replace the authenticator using the current code; then sign in and recover using one saved code. Save each newly generated set. Confirm sign-out and readiness after each completion. Wait for a new authenticator code between proof steps. Keep the old authenticator until replacement finishes. Do not intentionally lose both factors on your only demo identity.

Provider contracts were checked against the [native recovery API](https://supabase.com/docs/reference/javascript/auth-mfa-recovery-codes-regenerate) and [pinned Auth implementation](https://raw.githubusercontent.com/supabase/auth/v2.197.0/internal/api/recovery_codes.go); compatibility remains version/configuration-specific. The shared `D:\Data\Downloads\Policies` directory was unavailable. The original PDF/rubric, local-only tooling exception and all seven required business groups remain intact.
