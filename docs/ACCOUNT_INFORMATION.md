# Account information and savings policy

Implemented 3 November 2026 as the next PDF Business 3 slice (BR-05/06/07). This adds persisted information views and officer rate management; it does not enable deposits, withdrawals, loan issuance, repayment, interest credits or transfers. AWS remains undecided.

## Views and policy

Customer account reads remain `GET /api/v1/me/accounts`, filtered by the authenticated owner. Officer customer-detail reads use the same information mapping after role checks. Checking shows its balance; savings shows its balance, annual rate and estimated monthly profit; mortgage shows the stored monthly payment, next due date and principal remaining, with a toggle for its [two-week equivalent](#two-week-equivalent). Missing schedules display unavailable, never a fabricated zero payment. **Refresh accounts** reloads the rate and estimate.

Project policy, not a PDF-prescribed formula: rates are integer basis points (100 basis points = 1%), allowed from 0 through 2000. The initial rate is zero until an officer changes it. Estimated monthly profit is `balance_minor × annual_rate_bps / 120000`, rounded to the nearest minor unit, half up, using BigInt. For example, synthetic 10,000,000 VND at 6% yields 50,000 VND per month. This is an estimate at an unchanged balance/rate, not accrued interest or a credited transaction. Existing account currencies are never relabelled.

Mortgage information uses a **monthly** schedule, one of the PDF's permitted frequencies. The later [demo provisioning slice](DEMO_ACCOUNT_PROVISIONING.md) now supplies explicitly synthetic 0% schedules through a local-only officer endpoint and narrow insert grant. Existing schedules remain read-only; this is not a real loan policy or debt inferred from the generic account balance.

### Two-week equivalent

Added 25 November 2026 for the PDF's "each month or every two weeks" wording (BR-07). Project convention, not a PDF formula: the two-week amount is the same yearly total spread over 26 payments, `ceil(monthly_due_minor × 12 / 26)`, calculated on the backend with BigInt integer arithmetic and rounded up to the next whole VND (the VND minor unit). Rounding up means 26 payments never total less than 12 monthly payments; the yearly excess is at most 25 VND. Example: 4,250,000 VND monthly → 51,000,000 VND a year → **1,961,539 VND** every two weeks (26 × 1,961,539 = 51,000,014 VND).

Mortgage account reads add `biweeklyDueMinor` (decimal string) beside `monthlyDueMinor`. It is derived on every read from the stored monthly amount, not stored, and is `null` when the monthly amount is unavailable; checking and savings accounts omit it. No schema or migration changed. The account card on the customer home and the officer's customer details offers **Monthly / Every 2 weeks**. It switches the amount and label ("Monthly repayment" / "Repayment every 2 weeks") and, for the two-week view, notes that the amount is the equivalent of the monthly schedule. Responses without the field show the monthly view only.

Limits: this is an equivalent display, not a separate biweekly loan schedule. There are no two-week due dates (the next due date stays monthly), no interest recalculation or accelerated payoff (the demo loans are synthetic 0% samples) and no repayment processing.

## Officer rate changes

The officer workspace has **Manage savings rate**. `GET /api/v1/officer/savings-policy` returns `annualRateBps` and `revision`. `PATCH` accepts exactly those two fields plus a reason (5–500 trimmed characters). Customer access is rejected on the backend. A database transaction locks the policy, checks the expected revision, updates it and appends the officer, old/new rates, revision, reason and time. Concurrent stale writes return 409. Lost responses require reloading before another save. The global rate applies immediately to new estimates, not historical interest records or balances. Every response is no-store.

The new migration grants only policy reads/column-scoped updates, append-only audit insertion, and mortgage schedule reads. Existing balance-write restrictions remain. Client-facing database roles have no table grants.

## Evidence and limits

- Backend lint/build, all 83 tests and formatting passed.
- Existing Flutter suite: 169 tests passed; two additional account tests and one officer rate-form save/conflict test passed. Savings/mortgage widgets were rendered at 390-pixel width and 200% text without overflow. Flutter analysis and debug web compilation passed.
- `node scripts/check-account-information.mjs` passed 12 checks against a disposable PostgreSQL fixture using the restricted API role. It tested all three account types, ownership isolation, integer calculations, schedule reads, one winner for concurrent rate edits, audit records, denied balance/schedule writes and unchanged balances. The fixture was cleaned up.
- That fixture uses minimal profile/account tables plus the actual new migration. It is not a full historical-migration or browser/API acceptance run. Existing customer/authentication regression tests still pass.
- Two-week equivalent (25 November 2026): backend lint/build, all 173 tests and formatting passed, including exact/rounded-up values, values beyond 2^53, malformed input, `null` handling and the HTTP account response. Flutter analysis and all 343 tests passed, including the default monthly view, toggling, older responses without the field, a 320-pixel screen at 200% text and the officer customer-details page. Cards were rendered with the bundled font at 390/320 pixels and 100%/200% text and inspected. The disposable-PostgreSQL scripts were not re-run (no SQL changed); Edge and native acceptance remain open.

No sample accounts or money were automatically added to the normal demo. Newly provisioned customers still receive their original zero-balance checking account. Officers can now explicitly add synthetic savings/mortgage accounts through [demo provisioning](DEMO_ACCOUNT_PROVISIONING.md). Real account/loan administration and financial operations remain open. This slice alone does not complete all of BR-05–BR-08 or the account-management feature group.

For interactive testing, the user starts `run.bat` (which applies forward migrations), signs in as an officer and opens Manage savings rate. Use Find a customer → Add demo account to prepare synthetic savings/mortgage records, then refresh the customer's accounts. Human Edge acceptance and native Android acceptance remain open. The local runner/LAN files stay uncommitted. The shared policy directory was unavailable.
