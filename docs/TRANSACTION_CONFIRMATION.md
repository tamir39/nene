# Transaction-bound confirmation preview

Subsequent implementation: [LOCAL_TRANSFERS.md](LOCAL_TRANSFERS.md) adds a separate local demo sending path with its own signed purpose. This preview and its API remain unchanged in meaning: they cannot send funds or authorize the sending path.

Implemented 3 November 2026 as **BR-04/BR-09 support**, with the user's explicit choice to implement confirmation before money movement. The PDF, page 2 Business 2 and 4, requires transaction 2FA and valid/allowed transactions before persistence. This slice checks an authenticator against exact reviewed same-bank transfer details. It does **not** complete BR-04/BR-09, perform eKYC, post a transfer, change a balance or add transaction history. AWS remains undecided.

## Customer journey

Under an active VND checking account, choose **Try transfer confirmation · no money sent**. Enter another existing Nene checking account's 12-digit number and a positive whole VND amount. A ready registered authenticator is required; the app directs customers with missing/restricted setup to Transaction security.

The backend supplies source/destination account numbers, amount, currency, preview fee, expiry and whether the source currently has sufficient funds. Review these details and choose **Check authenticator · do not send** with a fresh six-digit code. Success says **Authenticator checked for these details. Transfer not sent.** It is never a payment receipt or permission to send money.

Zero-balance synthetic accounts can exercise this security check. The review explicitly says **Insufficient funds**; execution remains unavailable for every amount regardless of funds. The preview uses checking-to-checking VND, whole VND units, positive amounts up to 9,000,000,000,000,000 and a displayed zero preview fee. These are bounded demo decisions, not PDF rules, a production transfer quote or a settled funding/fee policy. Other account types, currencies, destinations and financial operations remain for later slices.

Editing details first cancels the old signed review. Cancellation is also available after factor confirmation, because nothing has been posted. After a definite rejected/reused code, check status and start a new review with a fresh code. One review permits one submitted proof; the shared rolling attempt budget prevents new reviews from bypassing throttling.

## Binding, replay and storage

The [earlier prototype](AUTHORIZATION_PROTOTYPE.md) demonstrated the safeguards in disposable tables. This implementation adapts those principles to the existing production session boundary, registered factor and shared setup/recovery proof reservation rather than registering the old fixture service.

1. SessionGuard validates the bearer with Auth and loads the active application profile. Services deny officers and customer-supplied owner/factor/challenge/revision flags. The source must belong to the customer; both accounts and their owners must be active, with distinct VND checking accounts. No recipient profile or balance is disclosed.
2. Review details are encoded in a domain-separated HMAC-signed token returned to the client. It binds a random review ID, customer, Auth session, source/destination IDs and account numbers, amount, currency, fee, policy version, active factor, security revision and ten-minute deadline. It is authenticated, **not encrypted**; keep it out of URLs, logs and persistent client storage. Altered details, another customer/session or a changed policy are rejected.
3. Creating a review writes **no intent or transfer record**. On confirm/cancel, PostgreSQL stores only security metadata: IDs, a keyed review digest, factor/revision, state and deadlines. No account numbers, amounts, setup keys, raw codes, review tokens or provider credentials are stored in `bank.transaction_confirmations`. This avoids introducing the proposed durable pre-authorization financial-details record while its lecturer interpretation remains open. This security-record distinction is an engineering interpretation, not lecturer approval.
4. The customer binding lock serializes confirmation reservations and lifecycle changes. A unique review ID permits only one provider attempt. Duplicate confirmation returns current status only; it never calls the provider again or replays session tokens. Cancellation defeats late verification. Account eligibility is read again before verification and after provider success; these reads are not atomic balance-locking/posting logic.
5. The shared setup/management/confirmation reservation rejects reused code fingerprints across purposes and reviews, with at most ten distinct proof attempts per customer in fifteen minutes, including successful attempts. The HMAC proof key remains backend-only. A recovery code, existing AAL2 session, local biometric unlock or previous provider success cannot replace this explicit registered-TOTP check.
6. Provider challenge/verify happens outside a database transaction. After success, the backend validates the returned owner, session, AAL2 and registered factor, then rechecks current ready binding/revision, account eligibility, cancellation, review expiry and a thirty-second verification lease before recording `factor_confirmed`. The result expires after at most two minutes and never beyond review expiry. The row is not a consumable financial authorization.
7. Flutter serializes confirmation and refresh through SessionOwner. It adopts the returned pair only when request, purpose (`transaction-confirmation`), security revision, owner and Auth session match. Logout invalidates delayed results. A duplicate has no pair to adopt. Code fields clear on backgrounding/submission/disposal; signed reviews stay in memory only.

Responses always report `executionAvailable: false`; status/confirmation/cancel also report `sent: false`. There is no execution/consume endpoint, balance-update grant, posted-history insert or identity-bypass flag. Future financial posting must not accept this preview's `factor_confirmed` result as authorization: implement its own exact-operation consumption, current security/identity/funds checks and atomic balance/history commit.

## API and states

All routes are customer-owned under `/api/v1/me/transfer-confirmations`, authenticated and `Cache-Control: no-store`.

| Endpoint | Exact input | Behavior |
| --- | --- | --- |
| `POST /review` | `{sourceAccountId, destinationAccountNumber, amountMinor}`; amounts are decimal strings | Read-only canonical review plus `reviewToken`, `requestId`, `revision`, `expiresAt`, `sufficientFunds`, `executionAvailable: false`, `identityCheck: "not_implemented"`. |
| `POST /confirm` | `{reviewToken, code}` | Reserves one proof for the review. First confirmed response has bound session pair, `factor_confirmed` and `replay: false`; a duplicate returns status and `replay: true` without tokens. |
| `GET /:id` | Own review UUID | Security status only; another customer's ID returns 404. No transaction details or tokens. |
| `POST /cancel` | `{reviewToken}` | Creates/updates a cancellation tombstone for that review, including before any proof. Nothing is reversed or refunded. |

Stored states are `checking`, `factor_confirmed`, `rejected`, `unknown`, `cancelled`. Status additionally reports `expired` or `invalidated` when deadlines or the stored session/current binding no longer match. A checking row past its lease reports unknown. `factor_confirmed` records the check for the reviewed details; it does not assert that a factor can never subsequently be removed directly at Auth, or that funds/identity remain valid.

`400` covers invalid fields/account eligibility or definite rejected/reused proof; `429` the shared rolling limit; `401/403` invalid authentication/role/owner/session; `404` unavailable owned status; `409` changed/restricted security or stale review; `503` unavailable/uncertain verification. The client never automatically retries a proof. Unknown outcomes clear local session ownership; no money has moved. A reload/new login discards the signed review; create a new review rather than inheriting another session's proof. Status is recoverable by its known ID after authentication, but the UI does not yet list previous confirmation attempts.

Closing/backing out of the preview discards local details; explicit Cancel/Edit revokes its signed review. An abandoned token otherwise expires at its original deadline. Metadata cleanup/retention, hosted behavior and full browser/native acceptance remain open. Financial execution is unavailable throughout, including when identity comparison or its high-value policy is unconfigured.

## Verification and demo

Run after the backend build:

```powershell
npm --prefix backend run check
npm --prefix backend run format:check
node scripts/check-transaction-confirmation.mjs
```

From `app/`: `flutter analyze --no-pub` and `flutter test --no-pub`. Optional `flutter test --no-pub --dart-define=CAPTURE_CONFIRMATION_UI=true test/confirmation_screen_test.dart` renders a synthetic, secret-free review to ignored `.tmp/confirmation-ui/review.png`.

Evidence on 3 November:

- Backend lint/build, 98 tests and formatting passed; Flutter analysis, 192 tests and the debug web build passed.
- Seventeen isolated Auth/PostgreSQL checks passed: read-only review, role/ownership, altered details, session binding, pre-confirm expiry/account closure, cross-purpose/cross-review replay, concurrent duplicate handling, security changes, cancel races, final-write expiry, uncertain provider outcome, secret-free metadata, unchanged balances/history and restricted grants. Real GoTrue validates the successful proof; controlled provider responses exercise timing failures. Owned fixtures were cleaned up.
- A 390-pixel widget review was rendered and visually inspected. Widget tests cover the not-sent result, edit-before-new-review cancellation, rejected proofs, background code clearing and missing setup. API tests cover mismatched handoff and delayed logout. This is not a live Edge or native acceptance claim.

For user testing, stop/restart your local runner so the forward migration and new backend are loaded, then open its Edge URL. Use two existing synthetic customers' checking accounts: sign in as one and enter the other's account number. Complete authenticator setup first. A zero balance is sufficient to test this preview, but will visibly fail the funds check. Wait for a fresh authenticator code if setup/recovery recently used the current one. Do not share secret-bearing screenshots or codes.

`run.bat` and LAN/port tooling remain local and uncommitted. No normal demo/emulator, paid provider or cloud service was started by this implementation. The shared policy directory was unavailable. PDF/rubric originals and all seven business groups remain unchanged.

Next: test the separate [local transfer flow](LOCAL_TRANSFERS.md), then implement the remaining identity and financial requirements. Keep [TRANSACTION_FLOW.md](TRANSACTION_FLOW.md)'s lecturer-interpretation questions explicit; this preview is not the completed financial flow.
