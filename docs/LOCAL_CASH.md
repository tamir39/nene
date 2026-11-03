# Local demo deposits and withdrawals

Implemented 3 November 2026 after the user requested deposits and withdrawals. This extends BR-08, with BR-04 transaction 2FA and BR-09 validity/atomic persistence. The PDF, page 2 Business 3, explicitly requires adding and withdrawing money. It does not specify a cash network, eligible account types, fees or a funding source. The rules below are bounded project decisions, not PDF wording or lecturer approval of simulation. AWS remains undecided.

## Behavior and limits

Customers can choose **Deposit demo funds** or **Withdraw demo funds** on their own active VND checking and saving accounts. Both use the same review, authenticator, cancellation, receipt and history flow as [local transfers](LOCAL_TRANSFERS.md). A completed deposit credits the bank account and debits simulated cash; a withdrawal debits the account and credits simulated cash. Each posts a typed credit/debit history entry. Back to accounts reloads balances, including savings estimates derived from the current balance.

Simulated cash represents test funds outside bank accounts. It is **not real cash, a wallet product, a payment-provider sandbox or an external settlement integration**. A backend-only local CLI creates 3,000,000 VND once per customer, shared across that customer's eligible accounts. The app cannot refill it. Repeating setup for another eligible account of the same customer prepares that account without adding more cash. Withdrawals replenish this simulated cash by reducing the actual demo account balance by the same amount. The existing transfer opening seed remains separate and is never silently rerun.

| Rule | Local implementation |
| --- | --- |
| Account/customer | Own active `is_demo` VND checking or saving account, active customer with `@example.invalid` email. No officer cash-operation route or client-selected customer. |
| Money | Positive integer whole VND below 5,000,000; zero demo fee. Deposit requires sufficient simulated cash; withdrawal requires sufficient bank balance. Recipient-side bigint overflow is rejected. |
| Reference | Current accepted sender/customer reference with matching profile name, case/version/revision/evidence and unexpired ready evidence. This is not actual face comparison or completed eKYC. |
| 2FA | Fresh registered TOTP for every operation. Review binds operation kind, account, amount, policy, customer, session, factor/security revision and reference. Backup codes and an elevated session alone cannot authorize it. |
| High value | Amounts at or above 5,000,000 VND are blocked while actual operation-bound comparison remains unavailable. This carries the local transfer policy into both cash operations. |
| Saving account | Same deposit/withdrawal rules as checking for this demo; no term lock, penalty, automatic interest credit or invented product policy. Hosted savings terms remain open. |
| Mortgage account | Neither operation is supported. A mortgage repayment is a separate unimplemented financial operation; sample schedules are unchanged. |

The UI labels simulation before confirmation and in the completed result. It never claims that cash was dispensed, received at a real branch or settled through a provider. Full BR-08 acceptance still needs human/native validation and resolution of any lecturer expectation for real/sandbox funding. This slice does not complete eKYC, interbank transfer, external payment, utility, map or chatbot requirements.

## Shared confirmation and atomic posting

One NestJS confirmation service and one Flutter confirmation screen handle preview, local transfer, deposit and withdrawal. Their signed policy, persisted purpose and session-handoff purpose are distinct. A deposit review cannot authorize a withdrawal or transfer; a preview still cannot move funds. The shared proof fingerprint/rolling attempt limit also prevents reuse of a code across these purposes and authenticator management.

Before verification, storage contains security metadata only; financial details stay in the signed in-memory review. Deposits use `local_deposit`, withdrawals `local_withdrawal`, with policies `local-cash-deposit-v1`/`local-cash-withdrawal-v1` and handoff purposes `cash-deposit`/`cash-withdrawal`. The existing ten-minute review, thirty-second verification lease, session binding and current-factor checks apply. The selected banking account occupies both internal account slots for cash reviews; no second bank account or transfer recipient is involved.

After provider verification, `bank.post_local_cash` rechecks the exact proof/purpose, current ready security revision, owned account, synthetic active profile, current reference and both available balances under row locks. It rechecks expiry after obtaining the locks. Bank balance, simulated cash balance, immutable receipt, typed history entry and consumed proof commit atomically. Same-customer security locks and account locks coordinate deposits, withdrawals and transfers; a simultaneous withdrawal and transfer cannot spend the same bank balance twice. Duplicate confirmation returns the existing state without another provider proof or posting. A posted operation cannot be cancelled/reversed through this flow.

The new financial function is executable only by `nene_api`. That role has no direct insert/update/delete grant on simulated cash or receipts, and still cannot directly update financial account balances or insert history. Client-facing Supabase roles cannot access these tables or execute the function. Seed preparation uses the owned local database's administrative CLI only. The simulation is separately gated by `LOCAL_CASH_ENABLED=true` plus `bank.local_cash_settings.enabled`, both off by default. Enabling requires non-production loopback Auth/database configuration; it does not enable local transfers or hosted financial activity.

Lost replies and provider failures produce an unconfirmed result, clear unsafe local session ownership and instruct the customer to check recent operations/history after signing in. Proofs are never retried automatically. The last ten attempts are available per operation kind; full posted history remains paginated by account/month. Reads can race an in-flight commit, so a pending snapshot is not a final failure. Active pending financial checks block starting another review. Existing conservative unknown-outcome and memory-only-session limitations remain; do not advise repeating an uncertain operation.

## API

Authenticated customer routes under `/api/v1/me/cash/:operation`, where `:operation` is exactly `deposit` or `withdrawal`; all responses are `Cache-Control: no-store`.

| Endpoint | Contract |
| --- | --- |
| `GET /configuration` | `{enabled, highValueThresholdMinor: "5000000", currency: "VND", cashBalanceMinor}`. Cash is an integer string, or null if unprepared. Reads only the authenticated customer's cash. |
| `POST /review` | Exact `{accountId, amountMinor}`. Returns signed `reviewToken`, `requestId`, `revision`, `operation`, `accountNumber`, amount/currency/zero fee, expiry, sufficient funds and `executionAvailable: true`. `identityCheck: "not_implemented"` still denotes actual comparison. Legacy source/destination number fields both identify this single banking account; cash is not a second bank account. |
| `POST /confirm` | Exact `{reviewToken, code}`. First success returns `posted`, `sent: true` (local posting only), receipt and bound rotated session pair. Duplicate returns status with `replay: true`, no provider tokens. |
| `GET /:id` | Owned, matching-kind status. Posted receipt includes id, `operation`, `accountId`, amount/currency and posting time. Cross-customer or cross-kind IDs return 404. Available after fresh sign-in. |
| `GET /` | `{operations: [...]}`, last ten owned attempts of the selected kind. |
| `POST /cancel` | Exact `{reviewToken}`. Cancels only unposted work; already posted returns 409. |

Invalid fields, missing reference, insufficient money, unsupported account or rejected proof return 400; authentication/role/session failures 401/403; unavailable owned/matching status 404; configuration/security/review conflicts 409; shared proof-attempt limit 429; unavailable/uncertain dependencies 503. Posted receipts contain no OTP, session tokens or photo data. Raw provider/SQL errors are not exposed in UI or fixture output.

## Test in the user-run Edge demo

1. Stop/restart `run.bat` to apply the forward migration and rebuild. No emulator is needed.
2. Choose an existing synthetic customer's active VND checking or saving account. Complete reference enrollment/officer acceptance and authenticator setup. If an account is not already marked demo, it must be empty with no history before preparation.
3. In another PowerShell window at the repository root, substitute its actual 12-digit account number:

   ```powershell
   node scripts/seed-cash-demo.mjs ACCOUNT_NUMBER
   ```

   The command verifies the running owned `supabase_db_nene-local` container/project label, prepares that account, creates simulated cash only if absent and enables the local flag. It does not change a bank balance, insert financial history, approve a reference or alter roles/security. Repeating it does not refill cash. Use it for another eligible account of the same customer if needed; the same cash balance is shared.
4. Stop/restart `run.bat` to load the flag. Open **Deposit demo funds**, review 100,000 VND and confirm with a fresh authenticator code. From a zero-balance account and fresh cash seed, expect bank balance 100,000 and simulated cash 2,900,000, plus one deposit credit entry.
5. Wait for a fresh code, then **Withdraw demo funds** for 40,000 VND. Expect bank balance 60,000 and simulated cash 2,940,000, plus one withdrawal debit. No real cash moves. Sign out/in to check recent receipts and monthly history.
6. Try insufficient funds, 5,000,000 VND, and a reused code; none should post. Mortgage accounts have no deposit/withdrawal buttons and backend attempts are denied. Changing the reviewed amount requires a new review/code.

The normal demo has not been launched or seeded by this implementation. `run.bat` and its LAN/port helpers remain local and uncommitted. No provider account, cost, cloud resource or publication was created.

## Verification

After `npm --prefix backend run check`, run `node scripts/check-local-cash.mjs`, `node scripts/check-local-transfers.mjs` and `node scripts/check-transaction-confirmation.mjs` sequentially so their disposable fixtures do not compete for local ports. Also run backend format checks, Flutter analysis/tests and a debug web build. Optional UI capture: `flutter test --no-pub --dart-define=CAPTURE_CONFIRMATION_UI=true test/confirmation_screen_test.dart` from `app/`.

Fourteen isolated cash checks passed: real GoTrue deposit and withdrawal; default-off configuration; roles/ownership/reference/funds/threshold; exact kind/detail binding; concurrent duplicates; shared code replay; seed idempotency across accounts; fresh-login receipts; saving/mortgage rules; shared cash exhaustion; withdrawal-versus-transfer competition; history-write rollback; cancellation; reference expiry; changed factor; provider uncertainty and restricted grants. Test reference metadata is simulated solely to isolate financial behavior; this is not photo/eKYC evidence. Controlled provider responses exercise races after real-provider success. Owned fixtures were cleaned; 12 local-transfer and 17 preview regression groups also passed.

Backend lint/build and 101 tests passed. Flutter cash review, direction, typed handoff, explicit simulation result, receipt recovery and uncertain-outcome tests passed alongside the preview/transfer tests. Deposit review and withdrawal result were rendered at 390 pixels and visually inspected. Flutter analysis, all 198 tests and the debug web build passed. Live Edge/phone/native, real cash integration and full lecturer acceptance remain unverified. The shared policy directory was unavailable.

Next: user acceptance of these local flows, actual operation-bound high-value identity comparison with the provider still undecided, and the remaining interbank/payment requirements in [ROADMAP.md](../ROADMAP.md).
