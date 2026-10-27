# Customer authenticator lifecycle plan

Status: **planning only, 27 October 2026**. The user requested enrollment, recovery and session-handoff planning before app integration. This document adds no customer endpoint, Flutter screen, migration or provider configuration. Normal demo MFA and financial execution remain disabled. AWS and the actual face-comparison implementation remain undecided.

Recommended direction: keep Supabase authenticator TOTP as the working candidate, with one active Nene factor per customer. Plan provider-native recovery codes for lost-authenticator replacement, subject to an isolated compatibility check. Do not introduce another OTP provider or a custom backup-code system. This is a proposed implementation policy, not a PDF-prescribed mechanism or completed BR-04 acceptance.

Follow-up evidence: [RECOVERY_SESSION_COMPATIBILITY.md](RECOVERY_SESSION_COMPATIBILITY.md) records working provider recovery and the original failed browser handoff gate. The subsequent [SESSION_COORDINATION_PROTOTYPE.md](SESSION_COORDINATION_PROTOTYPE.md) passes the isolated ownership/refresh gate with independent tab sessions and stateless Auth requests. The lifecycle remains unimplemented; backend purpose/revision rules and production app integration still precede demo MFA.

## Scope and evidence

The [PDF](../FinalProject_2026_2027.pdf), page 2 Business 2, requires transaction 2FA; OTP is an example. This lifecycle is minimal support for BR-04 and the shared financial flows, including BR-09. Profile entry/role separation support BR-01; the plan contributes TR-05/TR-06 design evidence. It does not replace BR-03 identity verification, add public signup or give officers a new reset/payment role. All seven business feature groups remain in [ROADMAP.md](../ROADMAP.md).

Read this with [TRANSACTION_FLOW.md](TRANSACTION_FLOW.md), [TOTP_COMPATIBILITY.md](TOTP_COMPATIBILITY.md) and [AUTHORIZATION_PROTOTYPE.md](AUTHORIZATION_PROTOTYPE.md). The existing experiments established provider TOTP enrollment, token rotation, replay hazards and backend operation safeguards. They did not implement customer enrollment/recovery, session adoption or financial posting. Their previous test results are not new lifecycle acceptance evidence.

The installed Flutter stack is `supabase_flutter 2.18.3`, `supabase 2.16.5` and `gotrue 2.27.3`. The Auth experiments used GoTrue `v2.197.0`; the backend uses the locked Supabase JavaScript SDK. Compatibility findings below are version-specific, not promises about every hosted configuration.

## One Profile entry, a few states

Use **Profile → Transaction security** (S06 in [SCREEN_MAP.md](SCREEN_MAP.md)). Reuse the lighter Open pocket palette and existing phone layout. These are steps within one customer feature, not new apps or officer workflows.

| View/state | Customer sees and can do | Backend meaning |
| --- | --- | --- |
| Not set up | Explain that an authenticator supplies codes for transaction confirmation; **Set up authenticator**. | No trusted Nene factor. Financial confirmation unavailable. |
| Setup pending | QR plus a manual setup-key option, then one code field and **Verify setup**. | Owned, expiring setup request; provider enrollment alone is insufficient. |
| Ready | Authenticator label, setup status, **Replace authenticator** and recovery-code availability if supported. | Verified provider factor matches Nene's active binding and security revision. This is not transaction authorization. |
| Backup codes, conditional | Show the newly generated codes once; explain saving them outside Nene and their recovery-only purpose. | Provider generation confirmed; plaintext is transient. Never offer a status endpoint that retrieves old codes. |
| Replacement/recovery pending | Explain the current step and **Check status** after uncertainty. | Financial authorization blocked while a change is incomplete. |
| Recovery required | **Use a recovery code**, when enabled, or clear help explaining that confirmation is unavailable. | No automatic password-only, email, reference-photo or ordinary-officer reset. |

TOTP has no resend action. The manual-key path supports someone using Nene and their authenticator on the same phone. Keep persistent labels, keyboard-safe scrolling, readable errors and large-text wrapping. Hide secret-bearing content while backgrounded, retaining only short-lived in-memory setup state needed to return from the authenticator app. Clear entered codes and clear all secrets on cancellation, expiry, sign-out or customer change. Do not capture secret-bearing screens for report evidence. User-directed saving of backup codes is separate from app persistence; do not promise control over another app's clipboard or screenshots.

## Enrollment and reauthentication

1. The backend starts a short-lived management request for the authenticated customer and purpose `enroll`. Require fresh password authentication for that same customer before issuing a setup secret. Proposed reauthentication is an explicit password sign-in followed by backend validation of the resulting same-user session and signed password-authentication timing against the request. A refreshed token's `iat`, client flag or existing `aal2` is not proof of a fresh password. Verify the provider's available claims in the next probe; never guess that an SDK method named `reauthenticate` performs this exact flow.
2. Bind the request to the resulting authenticated session, expected security revision and server-selected factor. Return a transient QR/manual key only for this owned setup. Keep the provider secret out of Nene records, logs, analytics, URLs, ordinary storage and replayable idempotency responses. Use request-scoped provider credentials on NestJS, never a shared mutable customer session.
3. The customer enters the first authenticator code. NestJS reserves the attempt, verifies the intended factor and reconciles provider state before committing Nene's factor binding. Provider and database writes are not atomic: an unknown result remains pending/restricted, not ready.
4. Reconcile the changed Auth session through the handoff contract below. Show **Authenticator ready** only when both provider verification and Nene binding are confirmed. If the backup-code probe passes, offer generation and one-time display as the next setup step; track whether codes were successfully issued separately from factor readiness. Generation requires a distinct unused code from the now-registered factor; do not reuse the reserved setup code as a new management proof.
5. Return to Profile or the transaction review. Setup authorizes no payment. The transaction needs its own fresh, operation-bound proof and deliberate confirmation.

Keep one pending management request per customer, with an opaque ID, purpose, owner/session, old/new factor IDs where needed, expected revision, expiry, attempt counters and minimal outcome/audit metadata. No passwords, tokens, raw codes or setup secrets belong in that record. First proposals are five minutes for fresh-password evidence and ten minutes for a setup/replacement request, checked by server time; these are design limits to validate, not PDF rules or TOTP code lifetimes. Reuse shared issued-attempt caps from the [prototype](AUTHORIZATION_PROTOTYPE.md) as a starting point across management and financial requests; creating another request must not reset the customer budget.

Use the same protected code-reservation boundary across setup, replacement and transaction confirmation for a given customer/factor. A successful setup or management code must not be reusable immediately as payment proof. Keep purpose-specific outcomes: a setup result, recovery result and transaction authorization cannot substitute for each other. The prototype's retention/tolerance assumptions need rechecking when this boundary is extended.

Cancellation, expiry and a lost QR response require provider reconciliation. Remove only the request's owned **unverified** pending factor. A lost verification response may already have verified it; do not delete a working factor or automatically create another. Reconcile the recorded attempt and provider result, or remain restricted if attribution is uncertain. Provider status alone must not attach an arbitrary client-created factor to Nene. Secrets cannot be recovered from status: restart a safely cancelled unverified setup when necessary.

For an aborted replacement whose new factor is still unverified, return to the old ready state only after reconciling that the old factor/binding is intact and cleaning up the pending factor. Already invalidated authorizations stay invalid. If the new factor is verified or cleanup is uncertain, remain restricted and resume reconciliation instead of silently rolling back.

## Replacing or losing an authenticator

| Situation | Proposed path | Completion boundary |
| --- | --- | --- |
| Old authenticator works | Fresh password plus a fresh proof from the registered old factor → create/verify replacement → commit new binding/revision → retire old factor. | Keep the old factor until the new one is verified. Block financial authorization during change; partial retirement/binding failures require reconciliation. |
| Old authenticator lost, backup code available | Fresh password plus one provider recovery code → restricted replacement request → enroll/verify new authenticator → bind it under a restricted in-progress revision → retire old factor and rotate backup codes using a fresh new-factor proof. | Enter Ready only after those steps reconcile. Recovery proof permits this replacement only. Revoke old refresh sessions and require clean sign-in after completion; new financial work still needs the new TOTP. |
| Neither authenticator nor backup code is available | Show the blocked/help state. | No customer reset is implemented or implied. A separately reviewed assisted-recovery identity/authority policy would be needed before claiming full recovery coverage. |
| Password forgotten | Follow the separately planned password-recovery path when implemented. | Password reset recovers the first factor only. It cannot remove MFA or approve a transaction. Hosted password recovery remains open. |

The recommended lost-phone mechanism is **Supabase's native recovery codes, if the compatibility gate passes**. Official documentation describes one-use recovery verification that upgrades the session to `aal2`; the JavaScript API currently requires an experimental option. This capability is not enabled or tested in Nene. [Recovery verification](https://supabase.com/docs/reference/javascript/auth-mfa-recovery-codes-verify).

Supabase's recovery-produced `aal2` session is not intrinsically restricted to replacement. Nene must enforce that restriction using its owner/session/purpose-bound management request, active-factor binding and security revision. Transaction endpoints must still demand a fresh TOTP from the registered factor for the exact operation; never accept recovery codes or generic `aal2` as payment authorization. Verified-factor self-removal requires `aal2`, making customer-owned replacement plausible without an officer/admin reset, but the complete sequence must pass the pinned-runtime probe. [Factor removal](https://supabase.com/docs/reference/dart/auth-mfa-unenroll).

Backup-code generation returns plaintext once. If the response is lost, check generation status; the old plaintext cannot be retrieved. Require fresh registered-factor proof before deliberate regeneration, then show the new set once. Do not silently generate repeatedly on retry or retain plaintext for replay. [Generation contract](https://supabase.com/docs/reference/javascript/auth-mfa-recovery-codes-generate). Regeneration invalidates the previous unused set, so explain that consequence before the customer's deliberate action. Prove reconciliation after lost regeneration replies. [Regeneration contract](https://supabase.com/docs/reference/javascript/auth-mfa-recovery-codes-regenerate).

If a recovery code was consumed but its result/session was lost, status lookup cannot replay that proof or migrate replacement permission to a new session. After fresh password authentication, resume only by explicitly rebinding the owned request after a fresh proof from its already verified, server-associated replacement factor; otherwise require another unused recovery code to supersede/restart it. If the last code was consumed before such a factor exists, remain blocked. Test this limitation and interruption between new-factor binding, old-factor retirement and backup rotation; never accept a consumed code again.

When an authenticated replacement/recovery begins, atomically enter the restricted state and invalidate outstanding authorizations. Check that restriction both when authorizing and at final consumption/posting, so an already approved operation cannot execute during the change. Serialize the boundary with consumption; an operation already committed before the change is a historical result, not something recovery reverses. Completion finalizes/increments the server-owned security revision and invalidates any remaining obsolete bindings.

Maintain a minimal server-side session-to-revision binding for security management and financial confirmation; a session cannot acquire the new revision merely by refreshing or reading status. Re-admit it only after the required fresh authentication and registered-factor proof. This supplies immediate backend rejection of obsolete authorization/session bindings even if an older JWT is still valid. Existing ordinary profile-read rules need not become a new MFA login gate.

Provider sign-out revokes refresh sessions; it does not instantly invalidate every issued access JWT. Test and enforce Nene's revision checks independently. [Sign-out semantics](https://supabase.com/docs/reference/javascript/auth-signout). Direct client access to Supabase Auth may change provider factors: reconcile missing/unexpected factors at security-sensitive boundaries, block mismatches and never silently adopt them into Nene. Ordinary officer edits, reference acceptance and test-fixture administrative resets are not customer MFA recovery.

If the experimental recovery capability fails the probe, keep total-loss recovery blocked and record the limitation. Do not quietly replace it with custom cryptography, an SMS vendor or an officer override. Enrollment can still be demonstrated without declaring recovery or financial activation complete.

## Session handoff contract

MFA verification may return a rotated access/refresh pair. The [current provider adapter](../backend/src/authorization-prototype/factor-verifier.ts) deliberately discards it. Session adoption must be designed separately from the durable authorization result: a token update is not a transaction receipt, and losing it must not trigger another payment.

1. NestJS independently validates the customer and originating stable `session_id`, purpose, request/version and current security revision. Extend the current [Auth boundary](../backend/src/auth/supabase-auth.service.ts), which currently exposes verified user ID/email, with verified signed claims or authoritative provider evidence. Never trust client-decoded claims, a client-supplied user ID or token bytes as a stable session identifier.
2. Before returning a rotated pair, NestJS verifies its access-token subject/session and provider result against the authenticated request; Flutter is not the authority for this check. Return the pair only in the immediate authenticated response to that successful request, alongside correlation metadata. Use `no-store` and production TLS; existing local debug exceptions stay narrow. Never persist tokens in management/operation records, logs, retry caches or status responses. A duplicate command can replay the safe business result, not credentials.
3. Flutter's Auth repository owns adoption. Capture the active customer, originating session, auth generation and request before starting. Validate the returned token/user and correlation, then permit one guarded adoption only if those values still match. A new login is a session transition; ordinary same-session refresh is not. Sign-out or a customer switch immediately invalidates pending adoption and clears sensitive UI state.
4. Serialize Auth mutations and coordinate refresh. A late network response must not install a session after logout, overwrite another customer, or revive an obsolete request. Recheck `/me` and read the existing operation/management status after adoption. Auth events alone never advance a payment. Failed profile/role validation leaves the app locked.
5. On a missing/uncertain handoff, use an existing valid session for status lookup, or require fresh sign-in and then look up the same operation. Never automatically resubmit a code or financial command. A new session may view an owned historical result; it must not inherit an old pending authorization. Supersede/review unprocessed work and obtain new checks before any later execution. Reading a management request likewise does not resume mutation authority: explicit backend rebinding/replacement needs the proofs described above.

The previous isolated experiment saw a short old-refresh-token reuse grace period. That is recovery evidence for that configuration, not a safe handoff strategy or promise that an old token remains usable. [Supabase session model](https://supabase.com/docs/guides/auth/sessions).

### Flutter implementation gate

The initial plan evaluated the documented `auth.setSession(refreshToken, accessToken: accessToken)` contract, which can avoid an extra refresh when supplied a fresh access token. The runtime probes below show why it is not the chosen owner boundary. [Flutter session API](https://supabase.com/docs/reference/dart/auth-setsession).

Source inspection and [runtime reproduction](RECOVERY_SESSION_COMPATIBILITY.md) found two hazards in the pinned [GoTrue Dart client](https://github.com/supabase/supabase-flutter/blob/gotrue-v2.27.3/packages/gotrue/lib/src/gotrue_client.dart): `setSession` awaits user validation before saving, without a logout-generation check; browser clients automatically exchange session events through a host-named BroadcastChannel even with persistence disabled. A second candidate client is therefore not isolated by default. Memory-only configuration and the current controller's stale-response checks do not prove safe SDK adoption.

The [follow-up coordinator](SESSION_COORDINATION_PROTOTYPE.md) passes delayed logout/account-switch, real-provider refresh ordering and two-tab tests using its own immutable memory snapshot and stateless explicit-token HTTP calls to Supabase Auth. It never reads a shared SDK session or imports broadcast credentials. Queue the entire verification request and validation/adoption with refresh, using the latest owned pair at dispatch. Access-token validation uses trusted Auth `/user`; the matching opaque refresh token must come from the trusted provider/backend response. Never accept arbitrary imported session JSON. Unknown rotation clears the owner and requires fresh sign-in; the isolated candidate conservatively does this for all mutation errors. Expected wrong-code error UX still needs a deliberate integration policy. No SDK fork, provider switch or persistence framework is selected.

Stopping the refresh timer does not undo an already-issued provider request. Production integration must remove competing SDK timers, session getters and event-driven adoption, route every rotation through the owner, and revalidate the backend profile. Each tab signs in separately; local logout immediately clears that tab and attempts to revoke only its captured provider session. It is not global sign-out across independent tabs. Late logout completion cannot clear a newer login. Disposing a local owner alone is not provider revocation. The user-facing guarantee is that logout wins over stale work and another customer's state cannot appear.

## Backend/UI boundary to implement later

These are proposed actions, not available routes; [API.md](API.md) remains the implemented contract.

| Action | Required server checks | Safe response/retry |
| --- | --- | --- |
| Read security status | Authenticated customer; own binding, provider reconciliation and revision. | Status, masked label, pending request ID and permitted next actions; no secrets. |
| Start setup/replacement | Customer role; recent password evidence; old-factor proof for replacement; one pending request; expected revision. | Owned request and transient setup material. Duplicate/lost replies reconcile first. |
| Verify setup | Owned session/request/factor; unchanged purpose/revision; shared attempt/replay limits; confirmed provider result. | Durable safe status; session pair only in its direct successful response. |
| Cancel or resume | Owned request; current provider and local state. | Cancel only safe unverified work, or report a completed/pending state; never delete blindly. |
| Generate/regenerate backup codes | Capability enabled and tested; fresh registered-factor proof; purpose/revision bound. | One-time plaintext display; status-only recovery and explicit regeneration after loss. |
| Recover using a backup code | Fresh password; owned recovery request; bounded single-use verification; financial restriction before replacement. | Replacement permission only. No arbitrary factor-ID deletion, officer override or transaction grant. |

Role/ownership and revisions come from server-controlled records. Log only minimal IDs, purpose, timestamps and safe outcome codes. Responses distinguish unauthorized access, stale state, exhausted attempts, provider unavailability and unknown outcome without leaking another customer's factors. Backend banking grants remain unchanged until an implementation explicitly requires a reviewed addition.

## Next probe and acceptance gates

The bounded [recovery/session probe](RECOVERY_SESSION_COMPATIBILITY.md) and follow-up [session coordination probe](SESSION_COORDINATION_PROTOTYPE.md) have run with synthetic users and the cached provider, without changing normal-demo MFA. The isolated browser owner and real refresh-ordering gate now pass. The backend lifecycle, app-configured transport, UI, hosted and native acceptance still need their own implementation evidence in the table below; these component checks do not complete the lifecycle.

| Gate | Required evidence before integration |
| --- | --- |
| Fresh password and ownership | Verified same-user password timing/session evidence; stale or refreshed-only proof rejected; another customer/officer cannot manage the factor. |
| Enrollment/replacement | First verification, duplicate start, lost QR/verification response, cancellation after verification, expired request and partial failure; old factor kept until replacement is verified. |
| Recovery capability | Generation on pinned Auth/SDK configuration; invalid/reused/concurrently used codes; replacement/self-removal after recovery; regeneration invalidating the old set; lost replies without secret replay; loss after the last code and between binding/retirement/rotation. |
| Authorization separation | Setup/recovery/old-factor codes cannot authorize money; cross-purpose replay blocked; direct provider changes cannot rebind Nene; old revision/session bindings rejected; an authorization created before a security change cannot be consumed during it. |
| Session adoption | Wrong user/session, delayed logout or another login, out-of-order responses, already-running refresh, expired/malformed tokens, timeout, database failure after provider success, two Edge tabs and late broadcasts. No automatic execution after resume/sign-in. |
| Secrets and UI | Memory-only state, restart requiring sign-in, no credentials in logs/URLs/retry records, same-phone manual key and return from authenticator, hidden secrets while backgrounded and cleared on cancellation/expiry/logout, understandable blocked/unknown states, keyboard and large text. |

Then implement S06 enrollment/status and the proven replacement/recovery path in one customer feature, with focused backend and Flutter checks. If browser acceptance is needed, ask the user to start `run.bat` in Edge; do not launch Android Studio/emulators. Hosted activation, secure persistence, any assisted total-loss reset and native acceptance remain separate unresolved work.

Financial integration still depends on real account rules, high-value policy and actual identity comparison, the lecturer's pre-authorization persistence interpretation, and operation-bound authorization/posting tests. This plan does not enable a transfer or complete BR-03/BR-04.

Planning verification: cross-checked the existing PDF source audit/requirement register, inspected current Auth/session code and pinned SDK behavior, and consulted the linked official provider contracts. Review documentation links, consistency and the staged diff; no runtime or browser test is claimed for this change. `D:\Data\Downloads\Policies` was checked and remains unavailable, so no shared-policy compliance claim is made. Original assessment files and local-only runner/LAN changes remain untouched.
