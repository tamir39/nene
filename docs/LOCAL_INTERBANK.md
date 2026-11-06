# Local other-bank transfer simulation

Implemented 7 November 2026 for **BR-04/08/09**, PDF page 2, Business 2–4. The user approved a clearly labelled local simulation because Nene has no interbank-network connection. This extends the existing transfer flow; it adds no new business feature or provider. Lecturer acceptance of simulation remains open. Face comparison and AWS remain undecided; reference acceptance is not completed eKYC.

## Rules and flow

An active synthetic customer chooses **Other-bank demo transfer** on a prepared VND checking account, selects a fictional bank and test recipient, enters an amount, reviews the destination and confirms with a fresh authenticator code. The chatbot's other-bank link opens this same form without choosing a recipient or sending anything.

- The source must belong to the customer, be active, explicitly marked as demo, and have sufficient existing funds. Only synthetic `@example.invalid` customer profiles qualify.
- The catalogue contains **Demo Bank A / Demo recipient A / 990000000001** and **Demo Bank B / Demo recipient B / 990000000002**. These are fictional external recipient records, separate from Nene banking accounts. Both start at zero; they are not a source of funds.
- Positive whole VND amounts below **5,000,000 VND**, with a zero demo fee. High-value posting stays blocked while actual identity comparison is unresolved.
- The sender needs an unchanged, unexpired officer-accepted reference and a ready authenticator. A fresh TOTP check is bound to the signed operation, source, recipient, bank and recipient names, amount, policy, customer, Auth session, factor and security revision. Recovery codes and an already elevated session do not replace it.
- Posting debits the Nene demo account and credits the separate simulated recipient balance. A receipt and a sender history entry labelled **Other-bank transfer (demo)** record the result. No real bank receives money. Returning to accounts reloads balances.

Reviews expire after ten minutes. Cancel/edit invalidates an unposted review; posted receipts cannot be cancelled or reversed here. An uncertain response requires checking status/history or signing in again, never assuming the transfer failed or automatically resending a code. Recent receipts remain readable after a fresh login and when new sending is disabled.

## Persistence and authorization

The flow reuses `ConfirmationService` with distinct purpose `local_interbank`, signed policy `local-interbank-v1`, and session-handoff purpose `interbank-transfer`. Preview, same-bank, deposit and withdrawal proofs cannot authorize this flow. Shared proof reservations also prevent reusing an authenticator code across operations.

NestJS resolves the server-owned destination catalogue and rechecks it after verification. `bank.post_local_interbank` is the only balance-writing entry point for this feature. It locks the feature gate, proof, security binding, source account, customer, bank, recipient and reference evidence; rechecks eligibility, funds, overflow and deadlines after blocking locks; and atomically commits the debit, simulated credit, immutable receipt, one debit-history entry and consumed proof. Exact repeated posting returns the existing result; changed receipt details are rejected. A failed write rolls the transaction back.

`nene_api` has read access to the catalogue/receipts and execute access to the narrow posting function. It cannot directly write balances, history or receipts. Client-facing Supabase roles cannot access these tables or execute the function. Amounts use integer strings/bigint. No OTP, session pair or identity image is stored in a transfer receipt.

Two independent gates default off: `LOCAL_INTERBANK_ENABLED` and `bank.local_interbank_settings.enabled`. The environment flag is refused in production or with non-loopback Auth/database hosts. Enabling same-bank transfers, cash or VNPay does not enable this flow. Gates prevent new reviews/proof dispatch; disabling is not a promise to cancel an already committed operation.

## API

Routes are under `/api/v1/me/interbank-transfers`, require an active customer and use `Cache-Control: no-store`.

| Route | Contract |
| --- | --- |
| `GET /configuration` | `{enabled, simulated: true, highValueThresholdMinor: "5000000", currency: "VND", banks}`. Banks contain `{code, name, recipients: [{accountNumber, name}]}`; the catalogue is visible while disabled. |
| `POST /review` | Exactly `{sourceAccountId, destinationBankCode, destinationAccountNumber, amountMinor}`. Returns the signed token/request/revision/expiry, source and destination details, `destinationBankName`, `destinationRecipientName`, amount/currency/zero fee, `simulated: true`, `executionAvailable: true`, and `identityCheck: "not_implemented"`. |
| `POST /confirm` | Exactly `{reviewToken, code}`. First success returns `state: "posted"`, `sent: true`, `simulated: true`, receipt and the bound `interbank-transfer` session handoff. This means locally posted only. An exact retry returns status with `replay: true`, no tokens and no second provider check. |
| `GET /:id` | Own attempt or immutable receipt, including snapshotted bank/recipient names, number, source ID, amount/currency/date and `simulated: true`. Foreign or absent IDs return 404. |
| `GET /` | `{transfers: [...]}` containing the ten latest owned attempts, including receipts. |
| `POST /cancel` | Exactly `{reviewToken}`; cancels an unposted attempt. Already posted returns 409. |

Invalid input, funds, reference or threshold returns 400; authentication/role denial 401/403; disabled or stale/conflicting review 409; shared attempt limiting 429; dependency failure or uncertain post-verification outcome 503. Existing pending/expired/invalidated states retain their ordinary meaning. Only the first confirmed response carries a fresh session pair; Flutter adopts it through its bound memory-only session owner.

## Local testing

The user starts the Edge demo using `run.bat`. Do not launch Android Studio or an emulator. No runner/LAN/port settings are changed by this feature.

1. Start/restart `run.bat` to load the updated application and forward migration. Use an existing synthetic customer with a funded, prepared VND checking account, current accepted reference and authenticator. Existing [same-bank seed](LOCAL_TRANSFERS.md#local-demo) or [simulated cash](LOCAL_CASH.md) rules remain the funding options; this feature does not seed or reset money.
2. In a separate PowerShell window at the repository root, substitute the source account's actual 12-digit number:

   ```powershell
   node scripts/enable-interbank-demo.mjs SOURCE_ACCOUNT_NUMBER
   ```

   The command checks the owned running Nene container, matching loopback database address/port and existing funded synthetic checking account. The database URL must use explicit `127.0.0.1` or `::1` matching the container binding; ambiguous `localhost` is refused. It enables only the private database gate and ignored backend flag; it does not change balances/history, approve a reference or modify an authenticator. It is safe to repeat. If configuration writing fails, rerun after fixing access; both gates are required.
3. Restart `run.bat` to load the flag. Open **Other-bank demo transfer**, select a fictional recipient and send **100,000 VND** using a fresh code. Expect the source balance to decrease by 100,000, one labelled debit entry and a receipt explicitly stating simulation.
4. Sign out/in and check the recent receipt and history. Check disabled/high-value/insufficient-funds behavior and confirm that the preview path still sends nothing. A lost response must be reconciled through status before starting another operation.

## Verification and limits

Reproducible checks:

```powershell
node --test scripts/interbank-enable.test.mjs
npm --prefix backend run check
npm --prefix backend run format:check
node scripts/check-local-interbank.mjs
```

Run Flutter analysis, tests and the debug web build inside `app/` using the installed SDK. The isolated interbank fixture applies the full migrations to disposable PostgreSQL/Auth, exercises real TOTP and restricted database grants, and never uses normal demo balances. Docker must already be available.

Passed: backend lint/build, **153 unit/HTTP tests**, backend formatting, **four activation-helper tests**, Flutter analysis, **242 Flutter tests** and the debug web build. Review/posting widget captures were rendered and visually inspected at 390px. API/widget coverage includes destination selection/binding, simulation labels, malformed receipts, purpose isolation, duplicate/uncertain outcomes, recent receipt recovery and account refresh. The disposable database script passes JavaScript syntax/format checks only; that is not evidence of SQL execution.

**Database/Auth runtime, human Edge and Android acceptance are pending**: Docker was stopped during implementation, and the user chose to test later. The normal demo was not launched. Existing payment and branch checks remain pending separately. This slice does not provide real interbank settlement, prove eKYC or resolve lecturer acceptance. The shared policy directory was unavailable; no compliance with unseen policies is claimed.
