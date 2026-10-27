# Browser session ownership and refresh coordination prototype

Date: **27 October 2026**. This isolated follow-up to [RECOVERY_SESSION_COMPATIBILITY.md](RECOVERY_SESSION_COMPATIBILITY.md) supports BR-04 and the [authenticator lifecycle plan](AUTHENTICATOR_LIFECYCLE.md). It tests the session boundary needed before customer integration. It does not complete transaction 2FA, eKYC, recovery management or financial posting. AWS and the face-comparison implementation remain undecided.

**The isolated browser ownership and refresh-coordination gate passed.** The final candidate passed 55 targeted Dart tests, four real-provider cases, nine two-tab Edge scenarios and an actual reload check. It owns one memory-only session per tab and coordinates mutations before any provider request is dispatched. It does not import provider sessions through a mutable GoTrue client. No normal Nene application code or MFA configuration is enabled by this experiment.

## Candidate and authority boundary

[SessionOwner](../experiments/session_coordinator/session_owner.dart) holds an immutable `OwnedSession` containing the exact access/refresh pair, authenticated user ID, stable session ID and expiry. Its value does not come from an SDK session getter. The separate [SupabaseAuthPort](../experiments/session_coordinator/supabase_auth_port.dart) receives explicit credentials for every request and holds no session. It creates no GoTrue client, subscribes to no SDK events, stores no credentials and starts no automatic refresh timer.

The owner serializes password sign-in, refresh and a request-bound exchange. The exchange's callback runs only after it acquires the same queue used by refresh; the queue remains held through provider completion, validation and adoption. A refresh queued behind a verification reads the newly adopted pair when it starts. A verification queued behind an already-running refresh receives that refresh's returned pair. Guarding adoption only after an independently dispatched verification would leave a remote rotation race; this candidate guards the dispatch itself.

Every exchange carries a `HandoffBinding` with request ID, purpose and security revision. The response must match it, and the binding is single-use within the current owner generation. Returned sessions must retain the same customer and stable session ID. A new login, logout or disposal invalidates older generations immediately. Late work cannot install a session, replace the later customer or grant authority to an earlier request.

The default owner deadline is 15 seconds. A provider/validation failure or uncertain mutation clears the current generation, rejects its queued work and requires explicit sign-in. It does not retry a consumed recovery code or replay a financial command. Timeout does not cancel a remote effect already performed; a late response is denied local adoption. The fixture HTTP port uses a total 10-second request/body deadline, a 64 KiB response cap and no redirects.

Logout clears the owner's session synchronously, then attempts provider revocation using only the captured old session and local logout scope. A later login cannot redirect that revocation toward the new session. Revocation failure is reported without restoring the old session; late completion cannot clear the newer login. Disposal is local cleanup and does not claim provider revocation.

Each tab signs in independently and retains its own session only in memory. Reload starts signed out. The candidate neither sends nor accepts SDK session broadcasts. **This is not global cross-tab logout:** logging out of one independent session does not clear another tab's owner. Session-wide or customer-wide revocation and the associated UI policy remain backend integration work. This design also does not defend against compromised code executing within the same page.

## Validation and trust limits

The port sends the supplied access token to Auth `/user` before decoding its claims. It then checks the returned user against the subject, the expected issuer/audience, the stable session identifier and expiry. The owner requires more than 60 seconds of remaining lifetime before adoption. These checks authenticate the access token through the trusted fixture service; decoding alone is not signature validation.

`/user` cannot authenticate an opaque refresh token or prove that it belongs with a supplied access token. **Refresh-token provenance must come from the immediate trusted provider/backend response.** The candidate must never accept a pair supplied through storage, browser events, arbitrary serialized JSON or an untrusted callback. The real-provider checks below show that their returned pairs work; they do not turn `/user` into a general verifier for arbitrary access/refresh pair combinations. Production handoff still needs NestJS to validate the authenticated request and provider response before returning the pair.

Provider authentication and offline JWT validity are different checks. The earlier recovery experiment observed `/user` rejecting a revoked session while the old token's signature and expiry still validated cryptographically. Neither local logout nor local ownership proves immediate rejection by every API that verifies only JWT signatures. Nene must enforce its server-owned security revisions, session admission and current permissions at sensitive management/financial boundaries, including final authorization consumption.

The HTTP adapter intentionally accepts only `http://127.0.0.1` fixture origins on ports 3001–3005. It does not support hosted endpoints or the normal browser preview proxy. A later integration must preserve production TLS, the existing narrow local debug exceptions, authenticated immediate responses, `no-store` handling and the backend's authorization boundary. No hosted configuration or browser CORS behavior is proven here.

## Evidence and final verification status

| Layer | Final evidence | Limits |
| --- | --- | --- |
| [Owner tests](../app/test/experiments/session_owner_test.dart) | **32 passed**, targeted analysis clean. Queue ordering through validation/adoption, duplicate bindings, wrong customer/session/binding, timeout, logout, account switch, disposal, captured-session revocation and late logout completion. | Fake `AuthPort` and synthetic pairs; no provider or browser in these tests. |
| [Auth port tests](../app/test/experiments/supabase_auth_port_test.dart) | **23 passed**, targeted analysis clean. Explicit credentials/local logout, restricted origins, malformed/oversized responses, redirects, total deadline/cancellation, claims and redacted errors. | Mock transport. Includes an explicit test that `/user` cannot validate opaque refresh-token provenance. |
| [Real-provider runner](../scripts/check-session-coordination.mjs) and [Dart child](../experiments/session_coordination_provider/probe.dart) | **Four passed**, including a final run after logout/deadline refinements. Run `15aae967-8406-4290-b2a8-32227be3abce` used Auth port 3001 and database port 3002; owned fixture cleanup completed. | Synthetic users with real TOTP enrollment/recovery verification; Dart VM transport, no Flutter UI, Nene banking database or money. |
| [Two-tab browser harness](../experiments/session_coordinator_web/README.md) | **Nine scenarios plus actual reload passed** after recompilation in isolated headless Edge `156.0.4314.42`. Zero unexpected requests/script errors; local/session storage empty. | Real browser/BroadcastChannel and compiled owner, fake Auth port. Legacy GoTrue controls carry synthetic tokens only. |
| Script/build checks | All three new Node scripts pass syntax/Prettier; all six new Dart files pass formatting. Provider child and browser compile; final provider source executes successfully. Malformed child input fails with sanitized output. | Build checks are not additional security or integration scenarios. |

The provider runner reuses the [isolated fixture](../scripts/lib/isolated-auth-fixture.mjs) with cached GoTrue `v2.197.0` and PostgreSQL 16, uniquely labelled containers/network, tmpfs database data, disabled runtime logs and explicit loopback bindings. It selects free ports within 3001–3005 and does not stop another project's process. Recovery capability is enabled only inside that disposable fixture. Synthetic credentials cross to Dart through private stdin, never command arguments, environment, files or result logs. The normal Nene database, credentials and Auth flags are not used.

The four provider cases establish:

1. **Verification before refresh:** hold the real recovery-verification response after the provider has consumed the code/rotated its credentials. A queued refresh makes no request until validation/adoption completes, then uses the exact returned refresh token. Another refresh after 11 seconds retains the same session and `aal2`.
2. **Refresh before verification:** hold an already-completed provider refresh response. Verification cannot dispatch until that refresh is adopted; its callback receives the returned refresh token and sends the returned access token. Verification and another refresh after 11 seconds retain the same session and `aal2`.
3. **Logout during verification:** logout clears memory while the real response is held. The late verification and queued refresh are rejected; no refresh request is issued and state stays signed out.
4. **Uncertain provider reply:** the provider consumes the recovery code, but the caller deliberately discards its response. The owner clears state and rejects the queued refresh. A deliberate fresh password sign-in creates a different `aal1` session, which can refresh without automatically replaying verification.

The 11-second waits exceed this fixture's 10-second refresh reuse interval. In-memory token-lineage assertions additionally check the exact pair passed to the next operation, so reuse grace cannot conceal stale credentials. These are sampled deterministic coordination cases, not a load test or a guarantee about every provider configuration.

The Edge harness proves that delayed native SDK broadcasts reach deliberately vulnerable legacy controls while the independent owners stay unchanged. It also checks delayed exchange/logout/account-switch behavior, peer logout isolation, serialized refreshes, timeout and an actual reload. The prior SDK hazard remains historical evidence; passing this different candidate does not make the earlier SDK import adapter safe. Browser checks use fake HTTP, while provider checks run in Dart VM: a combined real-provider browser flow has not been tested.

## Reproduction

Use the existing locked dependencies, local Flutter SDK and cached Docker images. From the repository root:

```powershell
node scripts/check-session-coordination.mjs
node --check scripts/check-session-coordination.mjs
node backend/node_modules/prettier/bin/prettier.cjs --check scripts/check-session-coordination.mjs
.tools/flutter/bin/cache/dart-sdk/bin/dart.exe format --output=none --set-exit-if-changed experiments/session_coordinator experiments/session_coordination_provider
```

The provider command owns and cleans its disposable fixture. It does not require the normal app demo. Optional provider-child compilation, also from the repository root:

```powershell
New-Item -ItemType Directory -Force -Path .tmp | Out-Null
.tools/flutter/bin/cache/dart-sdk/bin/dart.exe compile exe --packages=app/.dart_tool/package_config.json experiments/session_coordination_provider/probe.dart -o .tmp/session-coordination-provider-probe.exe
```

From `app/`, run the focused tests and analysis (both files were also run separately):

```powershell
..\.tools\flutter\bin\flutter.bat test --no-pub test/experiments/session_owner_test.dart test/experiments/supabase_auth_port_test.dart
..\.tools\flutter\bin\flutter.bat analyze --no-pub test/experiments/session_owner_test.dart test/experiments/supabase_auth_port_test.dart
```

These tests are executable evidence for the isolated candidate, not acceptance evidence for the current app's session controller. The existing backend and ordinary Flutter implementation are unchanged, so previous unchanged-code checks were reused rather than represented as new lifecycle acceptance.

Follow the [browser harness instructions](../experiments/session_coordinator_web/README.md) to compile the fixed assets, start the owned loopback server and run `scripts/check-session-coordination-web.mjs` against its printed origin. Browser ports remain within 4179–4199. The runner uses installed Edge in a disposable context; it installs no browser and does not use the personal Edge profile. Its sanitized result is `.tmp/session-coordination-web-result.json`. Close the owned static server when finished. No normal `run.bat`, Android Studio or emulator is needed for these isolated checks; the user still starts `run.bat` for actual app acceptance.

Final cleanup found no labelled experiment containers/networks and no listeners on used ports 3001, 3002 or 4179. The owned Edge context and static server were closed. All nine pre-existing containers retained the same IDs and remained running, including the Nene local stack and unrelated database. No normal-demo process was started or stopped.

## Remaining integration work

The candidate is under `experiments/` and is not imported by `app/lib`. Before Flutter integration, implement the backend lifecycle contract: authenticated request/purpose/factor/session ownership, fresh-password evidence, server-owned security revisions and admission, recovery-only authority, shared proof replay/attempt limits, restriction during replacement, cancellation/expiry and reconciliation after partial provider/database failure. Status lookup must not recreate consumed proof or grant a new session the old request's authority. Plain `aal2` remains insufficient for transaction permission.

Then wire the repository and UI to one owner, route every session-mutating operation through it, clear sensitive customer/profile state on invalidation, validate `/me` and permissions after adoption, and obtain safe status after interruptions without replaying a command. Define refresh scheduling, visible signed-out/uncertain states, tab/logout expectations and mobile lifecycle behavior. Enrollment/replacement/recovery screens, same-phone authenticator usability, native Android acceptance, hosted configuration, secure persistence and assisted total-loss recovery remain open.

No money moved; no cloud account, paid service, AWS integration, assessment-file edit, normal-demo MFA enablement or local-runner/LAN change is part of this prototype. The shared `D:\Data\Downloads\Policies` folder remains unavailable; no compliance with unseen policy contents is claimed.
