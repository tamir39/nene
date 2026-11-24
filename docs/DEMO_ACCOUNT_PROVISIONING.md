# Demo savings and mortgage provisioning

Implemented 3 November 2026 to support PDF p. 1 officer account administration (BR-02) and p. 2 account information views (BR-05/06/07). This is local demo support, not loan issuance, deposits, withdrawals, interest credits, repayment or completed transaction authorization. AWS and face comparison remain undecided. All seven business groups remain in scope.

## Test in Edge

The user starts local `run.bat`; the runner applies forward migrations and builds the updated app. Do not start Android Studio or the emulator for this check.

1. Sign in as an officer. Use **Find a customer** and open a synthetic customer whose email ends in `.invalid` or `.test`, such as a customer created with `example.invalid`.
2. Choose **Add demo account**, select **Savings**, enter a reason and acknowledge that the details are synthetic. Create the account. Customer details reload with a savings card at **0 VND**.
3. Add **Mortgage** for the same customer. For example: sample principal `12000000` VND, term `12` months, first due `2026-12-01`, plus reason and acknowledgement. The card shows a synthetic **1,000,000 VND** monthly payment and no loan issued.
4. Sign in as that customer and choose **Refresh accounts**. Checking, saving and mortgage appear in their own views. Another customer cannot see these accounts. An officer can change the savings rate through **Manage savings rate**, then the customer refreshes to see it; a zero balance still produces zero profit.
5. Repeating creation for an existing demo type is rejected. If a reply is lost, use **Retry same request**. If you leave/reload the form, check the customer before starting again; the server still prevents a second account of the same demo type.

The form never stores a request across browser reloads. It freezes the submitted details and UUID in memory during an uncertain outcome. A definitive validation rejection unlocks correction; permission/conflict failures require checking the customer. Session changes discard late results. Navigating away cannot cancel an already accepted server request, so returning to the customer reloads persisted state.

## Explicit project choices, not PDF mandates

- One additional savings and one mortgage demo account per active synthetic customer, both VND with zero generic balance. Existing checking accounts, currencies and balances stay unchanged. The uniqueness rule also covers closed demo accounts; reopening/replacement is not exposed.
- No seed balance or opening deposit. A sample mortgage principal belongs only to the labelled demo schedule; it is not available money or a real debt obligation.
- Monthly **0% sample** schedule: principal is a positive integer VND amount up to 1 trillion, term is 1–360 months, and principal must be at least the number of months so the regular amount is at least 1 VND. Regular amount is integer `floor(principal / term)`; a final installment would add the remainder. Example: 1,000,000 over three months gives 333,333, 333,333 and 333,334 VND. Only the initial regular amount, initial principal and first due date are persisted/displayed here; no repayment processing, schedule advancement or final-payment execution exists.
- First due date is a valid calendar date between 2000-01-01 and 2100-12-31. Historical dates are allowed for synthetic scenarios. The date does not advance automatically.
- These choices permit testing the PDF-required information views; they do not establish a real mortgage interest, approval or amortization policy. Future financial posting must explicitly exclude demo schedules or use a separately reviewed migration/fixture policy, never silently treat them as real liabilities.

## Backend contract and authorization

`POST /api/v1/officer/customers/:customerId/demo-accounts` requires a verified active officer session, a UUID `Idempotency-Key`, non-production configuration and loopback Supabase Auth. Hosted/production requests are rejected even if the screen is present. Target must be an active customer with a synthetic email suffix.

Savings body: `{ "type": "saving", "reason": "Demo account views", "syntheticConfirmed": true }`.

Mortgage adds exactly `principalMinor` (canonical integer string), `termMonths` (integer), and `firstDueOn` (`YYYY-MM-DD`), with `type: "mortgage"`. Reason is trimmed, 5–500 characters, with no control characters. Extra fields, client balances, interest or arbitrary account IDs are rejected.

Success/replay returns HTTP 201 `{ accountId, customerId }`, with `Cache-Control: no-store`. Failures: 400 invalid input/key, 401 invalid session, 403 role/environment/synthetic-data restriction, 404 missing/inactive customer, 409 reused key with changed details or an already existing demo type, 503 dependency failure. Read responses include boolean `isDemo`; Flutter labels both owner and officer cards.

Within one database transaction the backend serializes the officer/request key, locks the target customer, checks replay and type uniqueness, then inserts the zero-balance account, optional sample schedule and append-only request/audit record. The audit stores officer, customer, account, request ID, normalized synthetic inputs/reason and time. Identical retries return the original IDs; changed details conflict. Account, schedule and audit commit together or roll back together. A unique partial index prevents duplicates across officers, tabs and new request keys.

The migration adds narrow insert privileges for the demo marker and initial schedule. RLS requires a demo VND mortgage with zero balance and the documented integer formula. `nene_api` still cannot write financial balances, update schedules or delete request records. Client-facing Supabase roles cannot read/write banking tables. Banking access stays through NestJS. This endpoint is unrelated to the unregistered authorization prototype and does not bypass transaction 2FA for money movements.

## Verification

The following checks passed on 3 November 2026. Human Edge acceptance and native Android acceptance remain open. No new accounts were added to the normal demo by automated tests.

- Backend lint/build, all 87 unit/HTTP tests, and formatting passed (`npm --prefix backend run check` and `npm --prefix backend run format:check`).
- Flutter analysis, all 176 unit/widget tests and debug web compilation passed. Focused form tests cover local validation, date rejection, immutable same-key retries, duplicate clicks, narrow layout at 200% text, conflict state and late responses after sign-out. Readable widget captures at 390px were inspected with the approved palette; these are rendered-widget evidence, not interactive Edge acceptance. Captures are reproducible with `flutter test --no-pub --dart-define=CAPTURE_DEMO_UI=true test/demo_account_screen_test.dart` and saved locally under `.tmp/demo-account-ui/` (SDK fonts required).
- `node scripts/check-demo-account-provisioning.mjs`: 20 checks passed using disposable PostgreSQL, the actual foundation/customer/account-information/demo migrations, a minimal Storage schema for unchanged foundation policies, and the restricted API role. Checks cover concurrent creation, replay, ownership, synthetic-only restrictions, rounding, rollback/retry, audit and denied privileged writes. It calls the real controller/service directly, not a browser or full HTTP/Auth acceptance flow. Other identity/security migrations and real Storage are not exercised by this fixture.
- `node scripts/check-account-information.mjs`: 12 existing read/rate regression checks passed with the new marker column, including unchanged balances and denied schedule updates.

Disposable fixtures use owned containers and loopback test ports in 3001–3005, then clean up. They do not start the normal demo or claim unrelated ports. The shared policy bundle at `D:\Data\Downloads\Policies` was unavailable; no policy contents or compliance gates were inferred. Local launcher, LAN/proxy and port-repair files remain excluded from the PR.
