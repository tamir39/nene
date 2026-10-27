# Backend authorization safeguards prototype

Status: **local prototype verified on 27 October 2026**. Supports BR-04 and BR-09 design evidence without enabling transactions. Flutter + one NestJS API + Supabase remains the stack. AWS and actual face comparison remain undecided.

The [TOTP experiment](TOTP_COMPATIBILITY.md) showed that provider codes/challenges alone can be reused. This prototype puts operation binding and single consumption in PostgreSQL before relying on a provider result. **24 isolated integration checks passed**, including a real Supabase code presented concurrently through two service instances: only one provider verification and one authorization were recorded. A direct successful provider check did not authorize the other operation.

This is not a bank transfer or completed BR-04 delivery. There are no balances, posted transactions, customer-facing screens or production endpoints in the prototype.

## Implementation boundary

- [AuthorizationPrototypeService](../backend/src/authorization-prototype/authorization.service.ts) is an injectable service deliberately absent from `AppModule`. It exposes test-callable `prepare`, `confirm`, `status`, `cancel` and `consume` methods, not public HTTP routes.
- [SupabaseFactorVerifier](../backend/src/authorization-prototype/factor-verifier.ts) accepts only a local HTTP Auth endpoint. It uses an explicit request-specific bearer token, a five-second request deadline and bounded response parsing. Only an exact invalid-code response is a definite rejection; malformed responses, timeouts and ambiguous provider failures remain unknown. Successful responses return the verified user ID, never a reusable login/session authorization flag.
- [schema.sql](../backend/src/authorization-prototype/schema.sql) is a disposable fixture schema, **not a migration**. It refuses installation beside a `bank` schema. A fresh restricted test role can read fixture principals and change only the authorization fields it needs; it cannot change principal roles, material operation fields or Auth records. No normal migration or `nene_api` grant changed.
- Synthetic source/destination IDs, amounts and server-controlled eligibility/policy revisions exercise binding. They are not real account validation, balances, eKYC results or a high-value policy. An operation marked as requiring an identity comparison is always blocked because no actual comparison exists.
- The service accepts an actor supplied by a trusted caller. Production integration must wire the existing server-verified session boundary; this experiment does not expose a route that accepts a caller-supplied user ID. Provider verification additionally checks the returned user ID before recording authorization.

## Safeguards demonstrated

1. **Exact reviewed operation.** Each attempt records customer, factor, operation/version, canonical detail digest and policy revision. Changed amount, destination, version, factor, eligibility or policy invalidates the relevant authorization path. An idempotency key cannot be reused for another operation/details, and arbitrary provider challenge IDs cannot be submitted to `confirm`.
2. **Shared reservation before verification.** A short PostgreSQL transaction locks the customer record and reserves a keyed HMAC of customer/factor/code. The fingerprint does not include the operation or time bucket, so a second operation cannot evade it. A unique database key and shared row locks work across two pools/service instances. No process-local mutex is the security boundary.
3. **No long database lock around the provider.** Provider calls happen after the reservation commits. Finalization rechecks state, owner, policy, details and deadlines. Cancellation or supersession defeats a late successful reply. Expiry predicates on the final authorization/consumption writes prevent an earlier valid snapshot from granting authorization after its deadline.
4. **Honest recovery.** Exact repeated confirmation returns the recorded state without calling Supabase again. Recreating a service with the same fingerprint key retains this behavior. A different key fails closed. If provider success is followed by a database rollback, the operation stays unauthorized; the pending attempt becomes unknown after its lease expires, and its code remains reserved. Fresh attempts cannot revive late results from a superseded attempt.
5. **One synthetic receipt.** `consume` atomically changes an authorized fixture operation to consumed and assigns one synthetic receipt. Competing consumption keys cannot create two receipts; an exact retry returns the same receipt. This makes no debit, credit, external payment or financial history entry.
6. **Current usability is explicit.** Stored `state: authorized` is historical state. `authorizationUsable` becomes false after expiry or relevant policy/factor/eligibility changes, and the authorization ID is then omitted. `consume` always rechecks; a previously returned status is never permission to skip current checks.

The fingerprint key is a fresh 32-byte in-memory fixture key shared across service instances. Only its high-entropy key ID is stored for mismatch detection. Codes, Auth credentials and authenticator secrets are not written to prototype records or logs. Protected attempt fingerprints remain until fixture disposal; expiring proof claims are removed on subsequent customer confirmation. Production retention, key storage/rotation and maintenance remain to design.

## Conservative prototype limits

These are experiment settings, not PDF wording or final customer policies:

| Setting | Prototype behavior |
| --- | --- |
| Operation lifetime | Ten minutes by fixture default; checked using database time. |
| Pending challenge/verification lease | Thirty seconds; expired or superseded attempts cannot finalize. |
| Proof reservation | 120 seconds from reservation, conservatively covering the tested TOTP acceptance window and attempt lease. Do not change provider tolerance without revisiting this bound. |
| Authorization lifetime | At most two minutes and never beyond operation expiry. |
| Attempt budget | Five issued attempts per operation and ten issued attempts per customer in fifteen minutes, including abandoned/unknown attempts. Customer-wide locking prevents resets through new operations or concurrent requests. These are stricter than the earlier wrong-code-only proposal. |
| Uncertainty | No authorization from an unknown provider result, expired lease, stale policy, missing comparison or existing `aal2` session alone. |

The interpretation of persistent pre-authorization records remains unresolved for the final assignment implementation. Using disposable synthetic records to test safeguards does not settle that lecturer expectation.

## Verification and reproduction

The isolated runner uses the same cached GoTrue `v2.197.0` image as Nene and a temporary PostgreSQL 16 database. It reserves two free ports in 3001–3005, binds both explicitly to `127.0.0.1`, uses a dedicated Docker network and tmpfs data, and never pulls images or reads Nene's `.env` credentials. The completed run used Auth 3001 and PostgreSQL 3002. Temporary resources were removed by verified ownership label and ID; existing Nene and unrelated services remained as found.

From the repository root, with Docker Desktop running and the existing test images cached:

```powershell
npm --prefix backend run build
node scripts/check-authorization-prototype.mjs
```

[The runner](../scripts/check-authorization-prototype.mjs) exercises the compiled backend classes with real PostgreSQL transactions and two independent pools. Controlled provider fakes make cancellation, delayed replies, wrong-user results and uncertainty deterministic. A PostgreSQL constraint failure tests rollback after a successful provider response. Delays immediately before final writes test expiry boundaries. The final provider check uses real isolated Supabase Auth and a synthetic authenticator, not a human phone.

- **24 integration checks passed:** ownership/roles, restricted grants, identity gating, same-attempt and cross-operation concurrency, service recreation, changed request/proof, immutable receipt binding, cancellation, stale details/policy/factor, expiry, supersession, unknown outcomes, database rollback, attempt budgets, one-time consumption, status usability, final-write deadlines and real Auth verification.
- **72 backend tests passed**, including eight new provider-adapter tests. ESLint, TypeScript build and formatting passed. The first sandboxed HTTP test run hit local connection `EACCES`; rerunning with loopback access passed. This was a test-environment restriction, not ignored application failures.
- Original assessment files, normal migrations and `AppModule` are unchanged. No browser, `run.bat`, Android Studio or emulator was launched. No money moved, no cloud account/service was created and no provider cost was incurred.

This verifies two service instances/pools in one Node test process, not a multi-host load test. Prototype completion and lost-reply recovery are service-level checks, not an HTTP/UI restart journey. Provider session tokens are deliberately discarded: customer session handoff/refresh and factor recovery must be designed before real integration. Hosted behavior, PostgreSQL 17 deployment, real account rules, actual identity comparison, atomic financial posting and BR-04 acceptance remain unverified. The shared policy folder remains unavailable.

Next: review the factor choice and customer enrollment/recovery/session-handoff contract, then integrate the reviewed safeguards with real backend policies and the confirmation UI. Keep all financial execution disabled until its identity, account and authorization prerequisites are ready.
