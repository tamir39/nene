# VNPay checkout and demo utility services

Extension, 7 November 2026: [MOVIE_TICKET_DEMO.md](MOVIE_TICKET_DEMO.md) adds two fictional purchase offers and a read-only preview usable without provider credentials. Configured checkout reuses this lifecycle; the v2 signed review binds complete offer details and orders now store immutable `service_snapshot` values, including a migration backfill of the three original utility fixtures. Movie paid/failed results permit a fresh purchase, while pending orders still block duplicates. This does not issue real tickets or resolve BR-12 category/fulfillment acceptance. The original implementation evidence below remains dated and does not cover the new extension.

Implementation slice: **6 November 2026**, supporting BR-04/10/11 and the BR-14 service links. The user selected VNPay sandbox and approved **labelled demo electricity/water bills and phone top-ups**, with real settlement and phone credit disabled. Test merchant credentials and a public HTTPS callback address are still unavailable. Face comparison and AWS remain undecided.

This is a code implementation with synthetic test evidence, not a completed provider integration or full BR-11 acceptance. No account, tunnel, paid service or real payment is created by the implementation. Existing bank balances, cash simulation and account history are unaffected.

## Customer flow

Customer home → **Bills & phone demo**, or an activity link from **Ask Nene**:

1. View the server-owned fictional services: electricity **200,000 VND**, water **100,000 VND**, phone top-up **50,000 VND**. These fixed examples are project fixtures, not assignment rules, real customer bills or biller tariff data. The screen accepts no real subscriber details.
2. Until sandbox configuration is present, show the services and setup limitation with checkout disabled.
3. Once configured, select a service and review its exact amount. The backend requires an active synthetic customer, an accepted unexpired unchanged reference and a ready authenticator. Reference acceptance is still not completed eKYC. The existing **5,000,000 VND** block remains in force.
4. Confirm using a fresh authenticator code. A successful check issues one VNPay checkout for that signed review. It does not mark the service paid or debit a Nene account.
5. Tap **Open VNPay sandbox** separately. The existing app tab stays open; the provider opens externally. Its test-bank OTP is separate from Nene TOTP. No provider page opens automatically from chat, review or sign-in.
6. Return to Nene and check status. Only a signature-verified IPN with the matching terminal, reference, amount and order information can record sandbox payment success. The browser return page never updates payment state.
7. Recent sandbox payments can be recovered after signing in again. **Paid in sandbox** and **real service fulfillment unavailable** remain distinct. Nothing settles an electricity/water bill or credits a phone.

Each electricity/water example represents one fictional bill per demo customer. A pending checkout blocks another checkout for the same service; a paid example bill cannot be paid again. A failed result permits another attempt. Phone top-ups may be repeated after a previous result, but not while one is pending. A locally expired checkout remains unresolved until a signed provider result arrives: expiry alone does not prove non-payment or authorize another charge.

## Authorization, persistence and callbacks

The backend signs a ten-minute review binding customer, sign-in session, service, amount, factor/revision, reference version and request ID. Tampering or a different session invalidates it. Security-attempt metadata is stored before provider verification; the actual sandbox order is created only after TOTP succeeds and the same security/reference rules are rechecked. This preserves the existing distinction between security metadata and a completed financial transaction.

`bank.sandbox_payment_authorizations` reserves one confirmation attempt. `bank.sandbox_payments` stores immutable reviewed details, a unique provider reference, checkout timestamps and a separate provider result. Both are private to the backend database role. Neither changes `bank.banking_accounts`, `bank.account_history` or local cash balances. The order's `fulfillment` is constrained to `not_available`.

Shared proof reservations prevent reusing a code across authenticator management, transfer, cash and checkout purposes. Confirmation adopts the fresh Supabase session through `SessionOwner.exchange` with purpose `vnpay-checkout`; provider tokens are never persisted or returned on a duplicate. An uncertain verification/finalization result requires status recovery and, if session ownership was lost, a fresh sign-in. Do not submit the same code again or silently create another order.

Checkout URLs use VNPay PAY 2.1.0, SHA-512 HMAC, sorted encoded fields, whole VND multiplied by 100, UTC+07 timestamps and a project-selected 15-minute checkout window. The endpoint is fixed to the VNPay sandbox. Flutter validates the HTTPS host and exact checkout path before launching it. Signing secrets remain backend-only.

IPN parses the raw query before framework normalization, rejects duplicates/malformed fields, verifies the signature in constant time, checks the immutable order and updates under a database row lock. Success requires both response/status `00`. Definitive failure, pending and unresolved provider states are distinguished; late authenticated results remain valid after local expiry. Repeated results cannot create another payment. Return is static text with no reflected query, sign-in token, redirect target or database mutation. See the [official PAY guide](https://sandbox.vnpayment.vn/apis/docs/thanh-toan-pay/pay.html) and [hash migration examples](https://sandbox.vnpayment.vn/apis/docs/chuyen-doi-thuat-toan/changeTypeHash.html).

## Configuration and local testing

The user continues to start `run.bat`; no emulator or demo server is launched by this change. For the catalogue/disabled-state review, restart the user-run launcher and open **Bills & phone demo**. The migration must be applied before history/status checks; follow the existing migration procedure in [SETUP.md](SETUP.md). Keep launcher/port changes local and uncommitted.

Optional variable names are documented in [backend/vnpay.env.example](../backend/vnpay.env.example). Add values privately to the existing ignored **`backend/.env`**, which `dotenv/config` actually loads. The previous `.env.local` setup note did not match runtime loading and is corrected. Do not replace existing database/Auth settings or paste credentials into chat.

| Variable | Meaning |
| --- | --- |
| `VNPAY_SANDBOX_ENABLED` | `false` by default. Set `true` only after configuration and callback checks. Production or remote Auth/database activation is rejected. |
| `VNPAY_TMN_CODE` | Eight-character sandbox terminal code supplied by VNPay. |
| `VNPAY_HASH_SECRET` | Backend-only sandbox signing secret. |
| `VNPAY_RETURN_URL` | Actual public HTTPS `/api/v1/payments/vnpay/return` URL, without credentials, query or fragment. |

Register the corresponding `/api/v1/payments/vnpay/ipn` URL using the instructions supplied with the terminal. There is no configurable production checkout URL. The [access/setup record](VNPAY_SANDBOX_SETUP.md) retains registration steps and pending user actions.

[ngrok-policy.example.yml](../infrastructure/vnpay/ngrok-policy.example.yml) is an **unactivated policy example**: static project information at `/`, only GET IPN/return forwarded, all other paths/methods rejected. It uses the documented [custom-response action](https://ngrok.com/docs/gateway/traffic-policy/actions/custom-response) and [request path/method variables](https://ngrok.com/docs/gateway/traffic-policy/variables/req). It does not create a tunnel or prove isolation. Before use, validate actual endpoint behavior, including denied health/customer/officer/Auth/Storage paths and non-GET/encoded paths, with the owned loopback API port in **3001–3005**. Do not expose the preview or general API tree. Disable request inspection/logging for callback payloads through the actual account configuration. Public reachability, policy execution and VNPay delivery still need testing.

## Verification and remaining work

Tests use synthetic secrets/messages and do not contact VNPay. The [isolated payment check](../scripts/check-sandbox-payments.mjs) applies all migrations in disposable PostgreSQL/Auth containers and checks real TOTP, concurrent authorization/IPN, fresh-session recovery, private grants and unchanged bank balances/history. Run `npm --prefix backend run build`, then `node scripts/check-sandbox-payments.mjs` when Docker is available. Docker was stopped when checked, so this script has only passed syntax review; its runtime evidence is pending. It creates no provider account or payment and does not use the existing Nene database.

- Backend lint/build, **139 tests** and formatting pass. Coverage includes protocol/signature vectors, raw duplicate queries, HTTP public/private boundaries, binding/replay/refreshed sessions, reference changes, pending/paid bill duplicates, callback amounts/states and the concurrent status-read regression. Service/HTTP tests use dependency stand-ins; they do not prove PostgreSQL locks/grants or VNPay delivery.
- Flutter analysis and **230 tests** pass. New checks cover exact provider destinations, session/response binding, explicit launch, pending/unknown recovery, expiry, sign-out, demo-service chat links and the disabled setup state. Synthetic 390-pixel catalogue/review captures were rendered and visually inspected; these are widget evidence, not a live Edge/provider session.
- `flutter build web --debug` passes (including the tool's Wasm dry run). No demo server, emulator, tunnel or provider payment was started. Branch-map runtime/user testing remains deferred.

The original PDF and rubric remain unchanged; the shared policy folder `D:\Data\Downloads\Policies` remains unavailable, so no compliance claim is made.

Before marking BR-10 complete, obtain sandbox access, prove public callback isolation and record actual success, failure/cancellation, delayed and repeated notifications. Before marking BR-11 complete, demonstrate accepted bill/top-up behavior and resolve lecturer acceptance of simulated fulfillment or integrate a real service provider. This slice does not implement other-bank transfers or purchase/booking categories. Android/hosted/human acceptance and release/report evidence remain open.
