# Local same-bank demo transfers

Implemented 3 November 2026 for BR-04/08/09, following the user's explicit approval of these demo rules. PDF page 2, Business 2–4 requires transaction 2FA, valid/allowed transactions, balances and history. The PDF does not prescribe VND, a funding mechanism or this threshold. All seven business groups remain in scope; this bounded slice does not complete eKYC or the assignment's full transaction coverage. AWS remains undecided.

## Rules and customer flow

- Active VND checking accounts only, owned by active synthetic customer profiles with `@example.invalid` email addresses. Both accounts must be explicitly marked as demo accounts. The source belongs to the authenticated customer; destination differs from source.
- Positive integer whole VND, below **5,000,000 VND**, sufficient source funds, and a zero demo fee. Amounts at or above the threshold are blocked; no simulated identity success bypasses that gate.
- The sender needs a current officer-accepted reference with matching name/revision and unexpired ready evidence. Reference acceptance is not completed eKYC or an actual operation-bound face comparison. The recipient does not need a reference for receiving this local demo transfer.
- Every send requires a fresh code from the currently registered TOTP authenticator, bound to the exact signed review, customer, Auth session, policy, factor and security revision. Recovery codes and an already elevated session do not replace this step.
- Funds originate only from the explicit one-time local seed below. There is no customer add-money endpoint, deposit implementation, cash-out, external bank, loan issuance or payment-provider integration.

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
| `GET /configuration` | `{enabled, highValueThresholdMinor: "5000000", currency: "VND"}`. |
| `POST /review` | Exact `{sourceAccountId, destinationAccountNumber, amountMinor}`; returns signed token, request ID, revision, account numbers, amount/currency/zero fee, expiry and `executionAvailable: true`. `identityCheck: "not_implemented"` describes actual comparison, not reference acceptance. |
| `POST /confirm` | Exact `{reviewToken, code}`. First success has `state: "posted"`, `sent: true`, `executionAvailable: true`, receipt, request/revision/purpose binding (`same-bank-transfer`) and rotated session pair. Exact duplicate returns status and `replay: true`, without tokens or another provider verification. |
| `GET /:id` | Own attempt status. Posted receipt contains `id`, `amountMinor`, `currency`, `postedAt`; available after new sign-in or factor replacement. A receipt is historical evidence, not reusable authorization. |
| `GET /` | Last ten own attempts, newest first, with the same status/receipt shape. No other customer's attempts are exposed. Full posted entries remain available through paginated account history. |
| `POST /cancel` | Exact `{reviewToken}`; cancellation tombstone if unposted, `409` if already posted. |

Invalid fields/accounts/funds/reference/threshold or rejected proof return `400`; authentication/role/session denial `401/403`; unknown or foreign status `404`; disabled configuration, pending-check conflict or stale security/review `409`; shared rate limit `429`; unavailable or uncertain post-verification outcomes `503`. Pending states are `checking`, `rejected`, `unknown`, `cancelled`, with derived `expired`/`invalidated` as applicable. Finalization never exposes a durable intermediate `factor_confirmed` for local transfers: it commits with posting or rolls back. A result read may race an in-flight commit; refresh status rather than assuming a non-posted snapshot is final.

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

Next: validate this flow in Edge, settle deposit/withdrawal funding and cash-out rules, and implement those operations. Actual high-value comparison, other-bank transfers, payments/utilities, maps, chatbot, release and report coverage remain on [ROADMAP.md](../ROADMAP.md). No paid provider, cloud resource or publication was created.
