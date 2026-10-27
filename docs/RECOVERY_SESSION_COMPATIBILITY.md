# Recovery-code and session-handoff experiment

Date: **27 October 2026**. This tests the [authenticator lifecycle plan](AUTHENTICATOR_LIFECYCLE.md) before customer integration. It supports BR-04 and the shared financial flow; it does not complete transaction 2FA, eKYC or any money movement. AWS and the actual face-comparison implementation remain undecided.

**Recovery codes work in the isolated pinned provider, but the browser session-handoff gate did not pass.** A generation guard blocks delayed local imports in the test adapter; a late SDK event from another browser client bypasses that guard. Keep the normal demo MFA configuration and production app code unchanged until that boundary is resolved.

## Evidence boundaries

| Experiment | What is real | What is simulated or still absent |
| --- | --- | --- |
| [Recovery runner](../scripts/check-recovery-compatibility.mjs) | Cached GoTrue `v2.197.0`, disposable PostgreSQL 16, JavaScript SDK `2.117.3`, actual generated/consumed recovery codes, signed tokens and refresh/session behavior. | Synthetic users and factors; discarded replies model response loss in-process. No Nene banking schema, management requests, officer permissions or financial writes. |
| [Real-provider Dart handoff](../experiments/session_handoff_provider/probe.dart) | The recovery runner passes an actual upgraded pair privately to GoTrue Dart `2.27.3`; fresh adoption and a subsequent provider refresh both passed. | Single-client baseline only. No Flutter screen/repository integration, concurrent remote rotation or browser event coordination. |
| [Dart SDK tests](../app/test/experiments/session_handoff_probe_test.dart) | Installed GoTrue Dart `2.27.3` session methods and asynchronous state transitions; **32 tests passed**, targeted Flutter analysis passed. | Fake Auth HTTP replies and synthetic tokens. The [guarded import candidate](../app/test/experiments/session_handoff_fixture.dart) is test-only and cannot establish real provider signature/refresh validity or browser isolation. |
| [Two-tab browser harness](../experiments/session_handoff_web/README.md) | The same compiled Dart SDK, native BroadcastChannel delivery, two pages in installed headless Microsoft Edge `156.0.4314.42`; all five expected observations reproduced. | Fake HTTP/synthetic sessions, no real Auth credentials or app UI. Successful hazard reproduction is not a passed safety gate. |

The provider runner uses [the shared isolated fixture](../scripts/lib/isolated-auth-fixture.mjs): unique labelled containers/network, tmpfs data, disabled runtime logs, explicit `127.0.0.1` bindings and free ports 3001–3005. Recovery flags default to false and are enabled only for the positive fixture. The cached Auth image ID is `sha256:1736a63078f5922b198c4cbe50f80ab9a2d3b54fe8b7b6cfb2e9dc5dbbc12c6b`; PostgreSQL 16 is `sha256:4e6e670bb069649261c9c18031f0aded7bb249a5b6664ddec29c013a89310d50`. Nothing is pulled or provisioned remotely. This is not Nene's PostgreSQL 17 application database.

The fixture validates HS256 signatures, issuer, audience, expiry, subject and session identifiers before using its token claims as evidence. Its fresh signing secret is confined to the fixture process and disposable container configuration; it is never printed or saved in repository artifacts, and container removal removes that configuration. This is an experiment verifier, not the production JWT implementation. App integration still needs server-authenticated claims and current management/financial permissions.

The final provider/Dart run completed successfully with **28 observations**, including runtime, response-size and cleanup metadata; this is not a claim of 28 independent security tests. The five RFC-based synthetic TOTP helper tests also passed. Temporary credentials crossed the Node-to-Dart pipe through stdin only, never arguments, environment or files; only sanitized result fields were emitted.

The existing authorization prototype was rerun because its fixture changed: **24 checks passed** with recovery disabled by default. No backend production code changed. Targeted script formatting/syntax and documentation diff checks passed; the previously reported backend application test suite was not rerun or counted as new evidence.

## Provider observations

| Check | Observed result | Consequence |
| --- | --- | --- |
| Disabled provider flags / SDK option | Enrollment and verification returned `422` with their respective `not_enabled` errors; the disabled JavaScript experimental API rejected the call. | Recovery is opt-in; no normal-demo enablement follows from these tests. |
| Fresh password evidence | Signed password-method timestamp survived refresh unchanged while token `iat` advanced. Fresh password login changed the session ID and password timestamp. Modified unsigned claims were rejected by the fixture verifier. | A refreshed token's issue time is not recent-password proof. The backend's request-bound recency policy remains to implement. |
| Anonymous/AAL1 generation | `401 no_authorization` / `403 insufficient_aal`; factor inventory stayed empty after the denied attempt. | Failed generation did not create a factor in this check. |
| JavaScript generation/status | Ten codes returned; status contained counts, not plaintext. Duplicate generation returned `422 mfa_verified_factor_exists`. | Display once; a lost generation response requires deliberate regeneration, not plaintext retrieval. |
| Wrong code / other customer's code | `422 mfa_verification_failed`. | Basic proof and provider ownership checks worked. This does not test Nene officer authorization. |
| Valid code and sequential reuse | Success returned `aal2`, the same stable session ID, a rotated refresh token and `mfa/recovery_code` authentication evidence. Reuse returned `422`. | Recovery is one-use in this sequence and changes Auth session material. It is not transaction permission. |
| Concurrent same code | One `200`, one `422`; remaining count decreased once. | The sampled simultaneous pair consumed one code. This is not a multi-host/load-test guarantee. |
| Replacement | Old factor stayed verified while the new factor was unverified; after new-factor verification, customer-scoped old-factor removal succeeded. No administrative reset was used. | Provider-native replacement is feasible. Nene's restricted state, revision changes and partial-failure reconciliation are still absent. |
| Regeneration | An unused code from the old set failed; a code from the new set succeeded. Status still exposed no plaintext. | Regeneration invalidates the old set. No time-based code expiry is established here. |
| Discarded verify response | Repeating the consumed code failed; a new password login could see the reduced count but remained `aal1`. | Status cannot recreate the lost proof or its session pair. |
| Last code consumed, response lost | Count reached zero; retry failed; new password login could not regenerate (`403 insufficient_aal`). | Without the authenticator or another recovery proof, the planned blocked state is necessary. No password-only reset was added. |
| Recovery AAL2 authority | The provider allowed code regeneration using the recovery-upgraded session. | Supabase does not restrict it to Nene's replacement purpose. Backend purpose/factor/revision checks remain mandatory. |
| Global logout | Refresh returned `400 refresh_token_not_found`; `/user` returned `403 session_not_found`. The old access token's signature/expiry still validated cryptographically. | Signature validity and active-session validity differ. Nene must reject obsolete session/revision bindings independently of client logout. |

Official recovery-code APIs are experimental and describe one-time generation, consumption and regeneration. The observed behavior above is from this local version/configuration. [Generate](https://supabase.com/docs/reference/javascript/auth-mfa-recovery-codes-generate), [verify](https://supabase.com/docs/reference/javascript/auth-mfa-recovery-codes-verify), [regenerate](https://supabase.com/docs/reference/javascript/auth-mfa-recovery-codes-regenerate). The [pinned provider implementation](https://github.com/supabase/auth/blob/v2.197.0/internal/api/recovery_codes.go) and [configuration](https://github.com/supabase/auth/blob/v2.197.0/internal/conf/configuration.go) explain the feature flags; their existence is not evidence that hosted configuration or production lockout has been tested.

## Session-handoff results

The real-provider Dart child adopted the recovery-produced access/refresh pair without an additional refresh exchange, validated the subject/session through Auth, then explicitly refreshed once. The refresh token rotated; the user, stable session ID and `aal2` remained the same. Five `/user` reads and one `/token` exchange were observed. This proves a usable steady-state handoff with actual provider tokens, not safety during concurrent rotation or delayed browser events.

The 32 VM tests establish the following SDK behavior with controlled fake HTTP responses:

- A fresh pair passed to `setSession` validates the user without an extra refresh exchange. However, a response arriving after logout or a different customer's login can still install the old session. `Future.timeout` alone does not stop that installation.
- Raw `recoverSession` can install unvalidated serialized data without contacting Auth. It must not be treated as token verification.
- The test-only candidate first validates through the SDK contracts, checks customer/session/request/purpose/revision, uses a short-lived ownership ticket, then imports only through the inspected synchronous fresh-session path. It rejects expired/near-expiry/malformed tokens, stale generations, timeouts, duplicate adoption, reordered responses and same-customer fresh-login inheritance. It does not store secrets or enter production code.
- A local refresh finishing during validation invalidates the pending pair; a previously started SDK refresh cannot overwrite a later imported pair locally. This does not prove the adopted refresh token survives a concurrent provider-side rotation.

The five real-browser observations are decisive for the remaining gate:

1. Another in-page SDK client and the second tab receive the installed session despite no persistent storage.
2. Delayed unguarded `setSession` restores a signed-out session in both tabs.
3. Delayed unguarded `setSession` overwrites the later customer in both tabs.
4. A local generation guard rejects its own delayed reply after logout.
5. A late peer SDK broadcast still restores the old session, bypassing that local-only guard.

Both pages' local/session storage stayed empty; there were no unexpected page-network requests or browser-script errors. The test used a fresh disposable browser context, not the user's personal Edge profile. These findings reproduce the [pinned Dart client's](https://github.com/supabase/supabase-flutter/blob/gotrue-v2.27.3/packages/gotrue/lib/src/gotrue_client.dart) SDK behavior. They are not a demonstrated bypass in Nene's current UI: its controller has additional local sign-out/state guards, and no MFA handoff is integrated yet.

## Decision and next boundary

Keep provider-native recovery codes as the working recovery candidate. Keep every recovery result restricted to replacement in Nene; plain `aal2` is insufficient for money movement. Do not enable normal-demo recovery merely because provider capability passed.

**Before S06 integration, prove a browser-aware Auth session owner and safe refresh coordination.** It must prevent stale peer events as well as stale local replies, and show that the adopted refresh token remains usable with the real provider. Prefer a small repository/transport solution using the current stack; this experiment does not select an SDK fork, another Auth provider or persistent sessions. The existing local-only candidate must not be promoted as safe.

Still unverified: real Nene management APIs and session/revision admission; account/officer authorization; cross-purpose code reservation; cancellation and database/provider partial failures during lifecycle changes; production throttling/lockout; hosted availability/configuration; full assisted total-loss recovery; human authenticator/same-phone UI; native Android behavior; lifecycle-triggered authorization invalidation at financial consumption. Prior prototype tests are not evidence that these new paths exist. Keep the lifecycle acceptance table open where only provider or SDK fragments have been exercised.

## Reproduction and cleanup

With the locked dependencies, existing Flutter SDK and the two cached Docker images, run from the repository root:

```powershell
node --test scripts/totp-fixture.test.mjs
node scripts/check-recovery-compatibility.mjs
```

From `app/`:

```powershell
..\.tools\flutter\bin\flutter.bat test --no-pub test/experiments/session_handoff_probe_test.dart
..\.tools\flutter\bin\flutter.bat analyze --no-pub test/experiments/session_handoff_fixture.dart test/experiments/session_handoff_probe_test.dart
```

The [browser harness instructions](../experiments/session_handoff_web/README.md) cover compilation, the fixed-asset loopback server and installed-Edge automation. Ports stay in 4179–4199. No normal `run.bat`, Android Studio or emulator is needed. If reviewing the actual app later, the user still starts its Edge demo.

Early provider runs stopped because the test runner's 128 KiB response cap was smaller than the roughly 577 KiB generated QR SVG. The runner now bounds enrollment responses to 2 MiB while retaining a 128 KiB cap elsewhere; this was a fixture correction, not a provider AAL failure. Earlier `lastHttp` diagnostics could be stale before body parsing; they now capture the actual response status immediately. Temporary fixtures were cleaned on failed attempts too. Browser-tool initialization was unavailable, and the loopback/Flutter tooling required local sandbox access; the completed browser run used installed headless Edge.

Final cleanup verified no labelled experiment containers or networks and no listeners on used ports 3001, 3002 or 4179. The owned Edge context and static server were closed. Existing Nene and unrelated container IDs remained the same and running as before the tests. No existing service was stopped to obtain a port.

No production app code, normal Auth flags, banking schema/grants, assessment originals or local-only runner/LAN configuration were changed. No real customer identity, cloud account, paid provider or AWS service was used. The shared `D:\Data\Downloads\Policies` folder remains unavailable; no compliance with unseen policy contents is claimed.
