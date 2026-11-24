# Movie-ticket demo

Implementation slice: **7 November 2026**, supporting **BR-12** (PDF page 2, Business 5), with BR-04/10 checkout and BR-14 navigation. The PDF explicitly includes buying movie tickets in its flight/movie/hotel/e-commerce list. Movies are the first purchase category implemented; this is an implementation order, not a lecturer-approved waiver of the other categories. Their required breadth and acceptance of simulation remain open.

This slice reuses the existing Flutter app, NestJS API, PostgreSQL payment tables and selected VNPay sandbox. It adds no merchant account, provider, booking platform or real ticket fulfillment. Face comparison and AWS remain undecided. Existing high-value restrictions remain in place.

## Customer flow

Customer home → **Movie tickets demo**, or the allowlisted movie link from **Ask Nene**:

1. Choose one of two fixed fictional offers: **A Pocket of Sunshine**, demo session A, **90,000 VND**; or **The Little Comet**, demo session B, **120,000 VND**. Both are for fictional Nene Cinema, one ticket each. These are project fixtures, not real movie schedules or prices. No actual date, seat inventory, customer traveller data or reservation is collected.
2. Open the read-only preview to inspect the exact offer and total. Preview works even without VNPay credentials. It creates no order, reservation, payment or authorization, and asks for no authenticator code.
3. If sandbox configuration is unavailable, the preview clearly shows that checkout is unavailable. Browsing/preview remains usable. There is no fake payment-success control.
4. Once VNPay is configured, continue explicitly to secure checkout. The backend creates a fresh signed review after checking the synthetic customer, accepted unexpired reference and ready authenticator. Preview details cannot be submitted as authorization. The ordinary fresh TOTP and session-handoff rules apply.
5. After authorization, open VNPay separately and return to check status. Only a verified provider callback can mark a sandbox order paid. The result still says no real ticket, showing, seat or admission is provided. A successful sandbox payment is not fulfillment.
6. Recover owned recent movie orders after fresh sign-in. Pending checkout blocks another checkout for that exact offer. Paid/failed movie orders allow a new independently reviewed and authorized purchase. Electricity/water examples remain payable once; phone retains its existing repeat behavior.

Movie catalogue/history is separated from **Bills & phone demo** within the same reusable payment screen and API. Nene account balances and bank-account transaction history are unchanged; these are external sandbox orders. A lost or uncertain authorization response requires status recovery, not automatic resubmission.

## Backend contract and data

All customer routes require an active customer and use `Cache-Control: no-store`. Existing `/api/v1/me/payments` configuration, review, confirm, recent and owned status routes are reused. See [SANDBOX_PAYMENTS.md](SANDBOX_PAYMENTS.md) for the provider/signature/authorization boundary.

`POST /api/v1/me/payments/preview` accepts exactly `{serviceId}` and returns:

```json
{
  "service": {
    "id": "movie_matinee_v1",
    "name": "Demo movie ticket · matinee",
    "description": "One ticket for A Pocket of Sunshine at fictional Nene Cinema, demo session A. No real showing, seat reservation or admission is provided.",
    "amountMinor": "90000",
    "currency": "VND"
  },
  "amountMinor": "90000",
  "currency": "VND",
  "checkoutAvailable": false,
  "fulfillment": "not_available",
  "previewOnly": true
}
```

It returns no request ID, review token, session pair or checkout URL. No database writes, payment-provider calls, factor challenges or proof reservations occur; ordinary session validation still applies. Invalid/extra fields are rejected; officers cannot use the customer route. `checkoutAvailable` reports provider configuration only; it is not a promise that customer eligibility or authorization has passed.

Formal review accepts the same exact `{serviceId}` shape. New fixed IDs are `movie_matinee_v1` and `movie_evening_v1`; client prices, quantities, cinema/seat details and arbitrary provider URLs are not accepted. The signed v2 review binds the complete server-owned offer snapshot alongside the customer/session/factor/reference/amount/expiry. Confirmation rejects changed offer details and rechecks them before finalization.

`bank.sandbox_payments.service_snapshot` stores the reviewed five-field offer object. The additive migration backfills the exact three original utility fixtures, then requires a non-null object with string ID/name/description/amount/currency matching the payment columns. New movie amounts are constrained to their fixed fixtures. Existing column-scoped update grants do not allow changing the snapshot. Status/history read the stored snapshot, so later catalogue changes cannot silently rewrite an old order's details. The existing pending-per-customer/service unique index applies to movie offers as well; no extra booking database or service is introduced.

## Testing and limits

The user continues to start `run.bat` and chose to test later. For the credential-free flow, restart the user-run launcher after the forward migration, sign in as a customer, open **Movie tickets demo**, choose an offer and preview it. Confirm the amount and fictional-service text, then return to the catalogue. No authenticator prompt, order or balance change should occur. Chat requests such as “Buy movie tickets” and “Mua vé xem phim” open the same catalogue without selecting or paying for an offer.

Configured checkout testing remains dependent on VNPay sandbox credentials and a public callback endpoint, as recorded in [VNPAY_SANDBOX_SETUP.md](VNPAY_SANDBOX_SETUP.md). Do not enter real payment or customer data. The ordinary callback, expiry, duplicate, unknown-outcome and sign-in recovery checks remain required.

Reproducible automated checks are `npm --prefix backend run check`, `npm --prefix backend run format:check`, Flutter analysis/tests/debug web build, and `node scripts/check-sandbox-payments.mjs` after the backend build when Docker is already available. Unit/widget dependency stand-ins and synthetic image captures are not provider or database runtime evidence.

Passed: backend lint/build, **162 unit/HTTP tests**, backend formatting, Flutter analysis, **252 Flutter tests** and the debug web build. A 390px movie preview was rendered and visually inspected. Coverage includes no-write preview/role/input boundaries, offer mutation and response substitution, historical snapshot preservation, repeat/pending purchase rules, home/chat navigation, configured authorization and explicit no-ticket results. The extended disposable database/Auth fixture passes syntax/format checks only; it has not executed because Docker is unavailable. The user deferred live testing, and no demo, emulator or provider payment was started.

Full BR-12 acceptance remains open: real ticket fulfillment or lecturer-approved simulation, category breadth, actual provider evidence, and human/Android acceptance. The earlier interbank, payment and branch runtime gaps are not closed by this feature. The shared policy folder was unavailable; no compliance with unseen policy contents is claimed. Original assessment files and local-only runner/port configuration are unchanged.
