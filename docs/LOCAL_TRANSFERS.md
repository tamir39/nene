# Local same-bank demo transfers

Update 26 November 2026: transfers may now be up to 50,000,000 VND. Above 10,000,000 VND, or above 20,000,000 VND of posted transfers in one UTC+07 day, a server-side [face check](#high-value-face-check) against the accepted reference is also required. The 5,000,000 VND figures below describe the original slice; cash keeps that limit.

Subsequent extension: [LOCAL_CASH.md](LOCAL_CASH.md) adds separately gated simulated deposits and withdrawals. These can fund/debit prepared checking and saving accounts; the original transfer seed and its default-off gate remain unchanged. No real cash or external payment integration is added.

Implemented 3 November 2026 for BR-04/08/09, following the user's explicit approval of these demo rules. PDF page 2, Business 2–4 requires transaction 2FA, valid/allowed transactions, balances and history. The PDF does not prescribe VND, a funding mechanism or this threshold. All seven business groups remain in scope; this bounded slice does not complete eKYC or the assignment's full transaction coverage. AWS remains undecided.

## Rules and customer flow

- Active VND checking accounts only, owned by active synthetic customer profiles with `@example.invalid` email addresses. Both accounts must be explicitly marked as demo accounts. The source belongs to the authenticated customer; destination differs from source.
- Positive integer whole VND, below **5,000,000 VND**, sufficient source funds, and a zero demo fee. Amounts at or above the threshold are blocked; no simulated identity success bypasses that gate.
- The sender needs a current officer-accepted reference with matching name/revision and unexpired ready evidence. Reference acceptance is not completed eKYC or an actual operation-bound face comparison. The recipient does not need a reference for receiving this local demo transfer.
- Every send requires a fresh code from the currently registered TOTP authenticator, bound to the exact signed review, customer, Auth session, policy, factor and security revision. Recovery codes and an already elevated session do not replace this step.
- This slice originally funded transfers only through the explicit one-time seed below. The later cash slice adds bounded simulated deposit/withdrawal operations. No real cash-out, external bank, loan issuance or payment-provider integration exists.

Choose **Transfer demo funds**, enter the recipient number and amount, review both accounts and the amount, then **Confirm and send demo funds**. Success explicitly says that demo balances and history changed. Back to accounts reloads balances; both customers can read their own debit/credit history. The separate **Try transfer confirmation · no money sent** path retains its preview-only behavior, even after seeding.

Cancellation/edit revokes an unposted review. A posted transfer cannot be cancelled, edited, reversed or refunded through these routes. Reviews expire after ten minutes; one proof is submitted per review, with the existing thirty-second verification lease and shared code-use/attempt limits. Recent attempts and committed receipts are available after a fresh login. A lost response is **unconfirmed**, never assumed to mean not sent; check the result/history before starting another transfer. No automatic proof resend occurs.

## Authorization and atomic persistence

The local path has a separate signed policy (`local-vnd-under-5000000-v1`) and stored purpose (`local_transfer`). Preview tokens and preview confirmations cannot authorize it. Review details stay in the signed in-memory token; pre-authorization rows contain security metadata only. Immutable financial details are persisted only after successful verification. The broader lecturer interpretation of pre-authorization intent storage remains open in [TRANSACTION_FLOW.md](TRANSACTION_FLOW.md).

NestJS verifies the active provider factor and returned AAL2 session, then starts a database transaction. It rechecks current ready binding/revision, account ownership/eligibility and proof state. A narrowly granted `bank.post_local_transfer` function locks the proof, security binding, accounts in stable order, profiles and reference evidence. It validates current reference/name/version/expiry, synthetic accounts, funds, recipient overflow and proof deadlines again after locking. Debit, credit, immutable receipt, both history entries and the consumed `posted` state commit together. A failure rolls everything back. The function permits an exact posted retry without another debit; changed receipt details are rejected.

`nene_api` still cannot directly update balances or insert history/receipts. Only its narrow posting function can make these writes; client-facing Supabase roles cannot execute it or access banking tables. Existing read-only history permissions remain intact. Money uses PostgreSQL bigint and decimal strings; no floating-point conversion is used. No credentials, OTP values, reference images or provider session pairs are persisted in transfer records.

Two explicit gates default off: `LOCAL_TRANSFERS_ENABLED=true` in the ignored backend environment and `bank.local_transfer_settings.enabled`. Configuration refuses the flag in production or with non-loopback Auth/database hosts. Gates apply to new reviews and proof dispatch; stopping a send already in flight is not promised. Historical status and cancellation remain readable when the feature is disabled. The seed affects only the owned local Nene database, never a hosted account.

## API

All routes below are under `/api/v1/me/transfers`, require an active authenticated customer and return `Cache-Control: no-store`. Permission and ownership are enforced in NestJS, not just Flutter.

| Endpoint | Input and result |
| --- | --- |
| `GET /configuration` | `{enabled, highValueThresholdMinor: "5000000", currency: "VND", maxAmountMinor: "50000000", faceCheckAboveMinor: "10000000", faceCheckDailyAboveMinor: "20000000"}`. `highValueThresholdMinor` keeps its old value so app 1.0.2, which requires it, still works; it is no longer the transfer limit. |
| `POST /review` | Exact `{sourceAccountId, destinationAccountNumber, amountMinor}`; returns signed token (policy `local-vnd-up-to-50000000-v2`), request ID, revision, account numbers, amount/currency/zero fee, expiry, `executionAvailable: true` and `faceCheckRequired`. `identityCheck: "not_implemented"` describes actual comparison, not reference acceptance. |
| `POST /confirm` | Exact `{reviewToken, code}`, plus optional `faceCheckId` (UUID or null); 409 `FACE_CHECK_REQUIRED` when the rule applies without a usable check. First success has `state: "posted"`, `sent: true`, `executionAvailable: true`, receipt, request/revision/purpose binding (`same-bank-transfer`) and rotated session pair. Exact duplicate returns status and `replay: true`, without tokens or another provider verification. |
| `GET /:id` | Own attempt status. Posted receipt contains `id`, `amountMinor`, `currency`, `postedAt`; available after new sign-in or factor replacement. A receipt is historical evidence, not reusable authorization. |
| `GET /` | Last ten own attempts, newest first, with the same status/receipt shape. No other customer's attempts are exposed. Full posted entries remain available through paginated account history. |
| `POST /cancel` | Exact `{reviewToken}`; cancellation tombstone if unposted, `409` if already posted. |

Invalid fields/accounts/funds/reference/threshold or rejected proof return `400`; authentication/role/session denial `401/403`; unknown or foreign status `404`; disabled configuration, pending-check conflict or stale security/review `409`; shared rate limit `429`; unavailable or uncertain post-verification outcomes `503`. Pending states are `checking`, `rejected`, `unknown`, `cancelled`, with derived `expired`/`invalidated` as applicable. Finalization never exposes a durable intermediate `factor_confirmed` for local transfers: it commits with posting or rolls back. A result read may race an in-flight commit; refresh status rather than assuming a non-posted snapshot is final.

## High-value face check

Added 26 November 2026 for BR-03/BR-04/BR-09, after the user approved the rule below. It applies to same-bank transfers and [other-bank demo transfers](LOCAL_INTERBANK.md) only. Deposits, withdrawals and VNPay payments keep their limits (below 5,000,000 VND). This is a coursework safeguard: **not eKYC, not certified biometrics and not active liveness detection**.

### Rule

The bands follow Decision 2345/QĐ-NHNN (Circular 50/2024 appears to keep them). The PDF does not prescribe them.

- Each transfer may be up to **50,000,000 VND** (previously below 5,000,000).
- A transfer **needs a face check** when its amount is **above 10,000,000 VND**, or when the customer's **posted** outgoing same-bank and other-bank transfers for the current **UTC+07 calendar day** plus this amount are **above 20,000,000 VND**. Exactly 10,000,000, or exactly 20,000,000 in a day, needs no check.
- The accepted, unexpired reference photo and a fresh TOTP code are still required for every transfer. The face check is in addition to them.
- Not built: the 2345 trigger for a new device. Sessions are memory-only, so the server has no device history.

`bank.transfer_face_check_required(customer, amount)` is the only implementation of the rule. The API calls it when building a review (`faceCheckRequired`), when a face check is submitted and before the authenticator code is reserved. The posting functions call it again inside the posting transaction, after locking the customer's `bank.authenticator_setup` row. Every transfer posting path takes that lock, so two concurrent transfers by one customer see each other's totals.

### Flow

1. `POST /review` returns `faceCheckRequired`.
2. If it is true, the app takes a selfie and sends it to `POST /api/v1/me/face-checks` with the review token. Android also runs on-device blink/turn prompts with ML Kit and reports them as `liveness`. The web preview sends `{"blink":false,"turn":false}`. These flags are **stored as advisory data only**: the server cannot verify them.
3. The server validates and re-encodes the selfie (same rules as reference upload), reads the accepted reference from private Storage, and compares them. A match is valid for **5 minutes**, for that review only, and can be used once.
4. `POST /confirm` sends `faceCheckId` with the code. If the rule applies and no usable matched check is supplied, the server answers **409 `{"code":"FACE_CHECK_REQUIRED"}` before the code is reserved or verified**, so the same review and code can be used after a face check. The check must have at least 30 seconds of validity left, so it cannot expire during the code's 30-second verification lease.
5. The posting function marks the check used in the same transaction as the debit. If the rule changed between the pre-check and posting (a concurrent transfer by the same customer), posting rolls back, the attempt is recorded as `rejected` and the response is the usual 503 for post-verification failures: sign in again, then start a new review.

### Matching

- `onnxruntime-node` 1.31.1 (MIT) on the CPU, YuNet 2023mar face detection (MIT) and SFace 2021dec fp32 embeddings (Apache-2.0), compared by cosine similarity. Match when the score is at least **0.40** (`FACE_MATCH_THRESHOLD`, default `0.40`).
- The selfie must contain **exactly one** face at least 15 % of the photo's shorter side. Otherwise the result is `no_face` or `multiple_faces`. The reference must also contain exactly one such face; if not, the endpoint returns 409 `REFERENCE_UNUSABLE` and the customer needs a new reference.
- MiniFASNet V2 + V1SE (Apache-2.0) passive anti-spoof produces a score that is **logged and stored only**. It is never a gate: it was not calibrated on real phone selfies.
- Models load lazily on the first face check behind one shared promise, and each file's SHA-256 is checked again at load. One comparison runs at a time; at most three wait, and a caller stops waiting after 40 seconds (503).
- Feasibility spike, 26 November 2026, 117 public pairs: at 0.40, 1/79 same-person pairs were rejected (a dark image) and 0/38 different-person pairs were accepted. That sample is small; 0/38 has a 95 % upper bound of about 8 %, so this is not a false-accept rate. At Render free settings (0.1 CPU, 512 MB) a warm comparison took about 1.1 s and peak memory was about 190 MB.

### Limits

A matcher can match a printed photo, a screen replay or an injected image. The device liveness flags are self-reported, and the anti-spoof score is advisory. Use only agreed test images. Real-person captures need an agreed test-data procedure.

### Data

`bank.face_checks` stores one row per attempt: customer, idempotency key, review ID and keyed review digest, purpose, outcome (`pending`, `matched`, `not_matched`, `no_face`, `multiple_faces`, `error`), cosine score, anti-spoof score, threshold, device liveness flags and the created, completed, expiry and used times. **The selfie, the reference pixels and face embeddings are never stored**; the selfie is processed in memory and discarded. A trigger makes results write-once, and the database, not the API, sets completion and the 5-minute expiry. `nene_api` can insert pending rows and record an outcome and scores, but cannot set `used_at`, extend expiry or delete rows. Only the posting functions mark a check used. Client-facing roles have no access. Rows have no automatic cleanup yet.

### Endpoint

`POST /api/v1/me/face-checks`, customer only, `multipart/form-data`, header `Idempotency-Key` (UUID), `Cache-Control: no-store`.

| Field | Content |
| --- | --- |
| `reviewToken` | The token from a same-bank or other-bank review. |
| `liveness` | JSON string with exactly two booleans, for example `{"blink":true,"turn":false}`. |
| `selfie` | One JPEG or PNG file, at most 10 MiB and 4096 × 4096 pixels. The declared type must match the bytes. |

| Status | Body |
| --- | --- |
| 200 | `{faceCheckId, matched: true, expiresAt}` |
| 422 | `{matched: false, reason: "no_face" \| "multiple_faces" \| "not_matched", message}`. No score or embedding is ever returned. |
| 400 | Invalid fields, file type or image; not a transfer review; no accepted reference. |
| 401 / 403 | Not signed in; not a customer (checked before the upload is read); review of another customer or sign-in. |
| 409 | Review expired, already submitted or cancelled; authenticator changed; transfer gate off; key reused for another review; check not required (the rule is evaluated again now, so a review that said `false` can still get a check if the day's total has since grown); `REFERENCE_UNUSABLE`. |
| 413 | Selfie over 10 MiB. |
| 429 | Five failed attempts (`not_matched`, `no_face`, `multiple_faces`) for this review, or ten attempts by the customer in 15 minutes. |
| 503 | Models, Storage or matcher unavailable, busy or too slow. The attempt is recorded as `error`. |

Repeating a request with the same `Idempotency-Key` returns the stored result without comparing again.

### Hosting and models

Models are not committed. `npm --prefix backend run face-models` downloads them into ignored `backend/models/` from the pinned URLs in [backend/face-models.json](../backend/face-models.json) (opencv_zoo commit `48b10fa`, yakhyo/face-anti-spoofing release `weights`) and fails on any SHA-256 mismatch. Without the files the endpoint returns 503; other routes keep working. Render settings are in [HOSTED_DEMO.md](HOSTED_DEMO.md).

## Local demo

The user starts the Edge demo; do not start Android Studio or an emulator.

1. Stop/restart `run.bat` so the forward migration and updated backend/Flutter are loaded. Preserve the existing project ID, ports and database volumes.
2. Use two existing synthetic customers with active VND checking accounts, or create them through the officer flow. The source must be zero balance, never seeded, with no financial history. Complete the sender's reference enrollment/officer acceptance and authenticator setup. Reference capture still uses the existing notice/retention rules and agreed test images.
3. In a separate PowerShell window at the repository root, substitute the two actual 12-digit account numbers:

   ```powershell
   node scripts/seed-transfer-demo.mjs SOURCE_ACCOUNT_NUMBER RECIPIENT_ACCOUNT_NUMBER
   ```

   This explicitly prepares both accounts as synthetic, seeds **3,000,000 VND once** into the source, records the seed and enables the local gates. It is opening fixture preparation, **not a deposit or 2FA-authorized transaction**, and therefore creates no deposit history. Repeating the same pair is a no-op; it cannot reset or top up the source. A recipient must be empty or already prepared as a demo account. The command checks the running owned `supabase_db_nene-local` container and its project label before changing data. It writes only the local ignored backend flag, without printing secrets. It neither approves references nor changes roles/security.
4. Stop/restart `run.bat` again to load the flag. As the sender, select **Transfer demo funds**, review **100,000 VND** to the recipient, and use a fresh authenticator code. Expect sender **2,900,000 VND**, recipient **100,000 VND**, one debit and one credit with the same operation reference, assuming fresh zero-balance recipient and no other transfers.
5. Sign out/in and reopen **Transfer demo funds**: the sent receipt should appear under recent attempts. The old confirmation preview must still say not sent. Test an amount at or above 5,000,000 VND and insufficient funds; neither should post.

No normal demo accounts have been seeded by the automated checks. The one-time command is deliberately separate from the runner and migrations. `run.bat`, LAN helpers and local port changes remain uncommitted.

## Verification and limits

After building the backend:

```powershell
npm --prefix backend run check
npm --prefix backend run format:check
node scripts/check-local-transfers.mjs
node scripts/check-transaction-confirmation.mjs
```

From `app/`, run `flutter analyze --no-pub` and `flutter test --no-pub`. Optional `flutter test --no-pub --dart-define=CAPTURE_CONFIRMATION_UI=true test/confirmation_screen_test.dart` creates secret-free review/result images under ignored `.tmp/confirmation-ui/`.

Evidence: 99 backend tests plus lint/build/formatting; 12 isolated local-transfer checks and 17 preview regression checks passed. Real GoTrue TOTP and restricted PostgreSQL privileges exercise the successful posting; controlled provider replies exercise races. The transfer fixture seeds reference metadata solely to isolate financial checks: it does not test actual photos, officer acceptance or face comparison. Checks cover default-off gates, reference/funds/threshold/ownership, preview isolation, concurrent duplicate/spending, fresh-login receipt recovery, rollback on failed history insert, reference change/expiry, factor change, cancellation, one-time seed and database grants. Owned disposable fixtures are removed afterward.

Flutter widget/API checks cover the sent result, disabled gate, uncertain outcome/session clearing, receipt recovery, prior preview behavior and handoff binding. Review and sent states were rendered at 390 pixels and visually inspected. Flutter analysis, 195 tests and the debug web build passed; the updated workspace notice also passed its 12 targeted regression tests. Live Edge, phone/native and hosted acceptance remain open; the normal demo was not launched. The shared policy directory was unavailable, so no policy-bundle compliance is claimed.

Next: validate this flow and the separately enabled cash simulation in Edge; real funding/cash-out acceptance remains open. Actual high-value comparison, other-bank transfers, payments/utilities, maps, chatbot, release and report coverage remain on [ROADMAP.md](../ROADMAP.md). No paid provider, cloud resource or publication was created.
