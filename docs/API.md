# API contract

Local other-bank simulation added 7 November 2026: customer `/api/v1/me/interbank-transfers` configuration/review/confirm/status/recent/cancel routes use fictional bank and recipient records. [LOCAL_INTERBANK.md](LOCAL_INTERBANK.md#api) defines inputs, independent gates and explicit simulation results. The narrow posting function debits existing demo funds, credits a separate simulated recipient and writes the immutable receipt/history atomically; no real bank network is called.

Activity assistant added 5 November 2026: customer-only `POST /api/v1/me/assistant/messages` accepts a bounded question and optional history-month context, returning plain-text answers and allowlisted activity descriptors. It does not query accounts or execute financial operations. See [ASSISTANT.md](ASSISTANT.md#api-and-authorization) for schema, supported intents and incomplete bill/top-up coverage.

Branch navigation added 5 November 2026: customer-only `GET /api/v1/me/branches` reads the fictional Nene office catalog; `POST /api/v1/me/branches/route` accepts only a starting latitude/longitude and returns the walking route to the server-selected nearest office. See [BRANCH_NAVIGATION.md](BRANCH_NAVIGATION.md#api-and-storage) for coverage, response/error rules, privacy and local provider limits.

Local cash operations added 3 November 2026: customer `/api/v1/me/cash/:operation` routes (`deposit` or `withdrawal`) provide configuration, review/confirm, recent/status and cancellation. See [LOCAL_CASH.md](LOCAL_CASH.md#api) for exact inputs, local simulation and typed receipt rules. No real cash or external provider integration is implied.

Local synthetic transfers added 3 November 2026: `/api/v1/me/transfers` provides configuration, review, confirm, recent/status and cancellation. [LOCAL_TRANSFERS.md](LOCAL_TRANSFERS.md#api) defines exact inputs and the local-only posting boundary. Confirmation can now atomically update seeded demo balances and both history entries; preview routes still cannot.

Transaction-bound confirmation preview added 3 November 2026: customer `/api/v1/me/transfer-confirmations` review/confirm/status/cancel routes bind a registered authenticator check to exact same-bank details. [TRANSACTION_CONFIRMATION.md](TRANSACTION_CONFIRMATION.md#api-and-states) records payloads, session/expiry/replay rules and the explicit `sent: false` boundary. Those preview routes never execute a transfer.

Authenticator replacement/recovery added 3 November 2026: customer-only `/api/v1/me/security/management` status and `start`, `prove`, `resume`, `enroll`, `verify`, `issue-codes`, `finish`, `cancel` POST commands. See [AUTHENTICATOR_MANAGEMENT.md](AUTHENTICATOR_MANAGEMENT.md#implemented-api) for exact inputs, session handoff, restrictions and interruption rules. These endpoints never authorize a payment or permit officer MFA reset.

History update, 3 November 2026: `GET /api/v1/me/accounts/:accountId/history?month=YYYY-MM&cursor=<optional UUID>` returns customer-owned posted entries in pages of 25. See [ACCOUNT_HISTORY.md](ACCOUNT_HISTORY.md#api-and-storage) for response fields, UTC+07 month boundaries, cursor validation and permission/error rules. History reads do not expose direct write access.

Account information update, 3 November 2026: [account views and savings policy](ACCOUNT_INFORMATION.md) adds type-specific read models, monthly savings estimates, stored mortgage schedules and officer-only audited rate changes. [Demo provisioning](DEMO_ACCOUNT_PROVISIONING.md#backend-contract-and-authorization) adds `POST /api/v1/officer/customers/:customerId/demo-accounts`, local-only officer authorization, idempotent requests and `isDemo` on account reads. No financial posting or real loan issuance is enabled.


Customer authenticator setup/status endpoints added 3 November 2026: see [AUTHENTICATOR_SETUP.md](AUTHENTICATOR_SETUP.md) for `GET /me/security`, `POST /me/security/setup` and `POST /me/security/verify`, permissions, payloads, no-store responses and limits.


Status: private reference enrollment/review added on 2026-10-27 to the first local customer/account flow. Supports BR-01/BR-02 and partial BR-03/BR-05, plus TR-03/TR-06. See [CUSTOMER_FLOW.md](CUSTOMER_FLOW.md) and [REFERENCE_FLOW.md](REFERENCE_FLOW.md) for decisions and remaining security work.

Base path: `/api/v1`. The Flutter client obtains its session from Supabase Auth and sends `Authorization: Bearer <access-token>` to NestJS. Banking data is never queried through the mobile Supabase database client.

| Endpoint | Access | Response |
| --- | --- | --- |
| `GET /health` | Public | Liveness only: `status`, `service`, `check`. Does not claim the database or identity service is healthy. |
| `GET /me` | Supabase session plus active server-owned profile | `id`, `email`, `displayName`, `role`, nullable `phone` and `address`. |
| `GET /me/accounts` | Active customer | `{ accounts: Account[] }`, scoped to the authenticated customer. |
| `PATCH /me/contact` | Active customer | Accepts only `phone` and `address` (nullable); returns the updated `/me` profile. |
| `POST /officer/customers` | Active officer; local demo activation configured | Requires UUID `Idempotency-Key` and `email`, `displayName`, `phone`, `address`, `initialPassword`; returns `CustomerDetail`. |
| `GET /officer/customers?query=...` | Active officer | `{ customers: Customer[] }`; name/email/phone search with a query of at most 100 characters, at most 20 results. Empty query returns no rows. |
| `GET /officer/customers/:id` | Active officer | `CustomerDetail` for an active customer; unknown/disabled customer returns 404. |
| `PATCH /officer/customers/:id` | Active officer | Accepts `displayName`, `phone`, `address`, `requestReason`; returns updated `CustomerDetail`. |

NestJS validates the token through Supabase Auth, then reads the matching `bank.user_profiles` row through the restricted database login. Supabase user metadata and client-supplied role values cannot grant officer access. Routes require authentication by default; only explicitly public routes bypass the guard.

`Customer` contains `id`, `email`, `displayName`, `phone` and `address`. `CustomerDetail` adds `accounts`. Each `Account` contains `id`, `accountNumber`, `type`, `currency`, `balanceMinor` and `status`. Account numbers and integer balances are decimal strings to preserve precision. The initial account is a VND checking account at zero. Existing foundation demo customers can legitimately have an empty account list.

Unknown or missing writable fields are rejected. Nullable phone/address keys must still be supplied; `null` clears them. Display name is 1–120 characters, email at most 254, phone 5–32 permitted contact characters including a digit, address 1–300 when present, initial password 12–128, and an officer request reason 5–500. Text input rejects control characters. The backend assigns customer role, identity/account IDs, currency, type and opening balance. Customers cannot edit name/email, access officer search, or supply another customer's identity. Officer edits require a reason describing the customer's request; sign-in email changes remain deferred. The edit audit records submitted field names rather than copying old/new personal values.

Creation replies use 201, including successful retries. A retry must retain its key and complete original payload. A changed payload (including password) with the same key returns 409. Concurrent retries serialize on the saved request. A duplicate email belonging to another Auth identity is rejected; it is never adopted. The password is not returned. Successful customer creation includes profile and initial account in one PostgreSQL commit after Auth is reconciled.

Creation failure handling distinguishes a definitive rejection from an uncertain outcome:

| Response | Meaning and client recovery |
| --- | --- |
| `400` | Invalid input/key, including allowlisted Auth email/password validation rejections after the reserved identity is confirmed absent. The form can correct details and use a new request key. |
| `409` with `code: "CUSTOMER_EMAIL_EXISTS"` | Auth confirmed a duplicate email and the reserved identity is absent. The form can edit details or return to search; the existing identity is unchanged. |
| Other `409` | Request-payload or reserved-identity conflict. Preserve the original key/body; do not silently create a replacement request. |
| Timeout, `503`, or an unreadable success response | Creation is unconfirmed. Retain the original key/body and retry to reconcile that operation. |

Flutter retains a pending request through ordinary background/resume and same-user token refresh. Every command still carries a bearer token and is authorized on the backend. Sign-out or confirmed session/permission changes clear protected state; process termination loses the in-memory key/password. An incomplete reservation after that loss needs trusted local investigation, as described in [CUSTOMER_FLOW.md](CUSTOMER_FLOW.md).

Creation is available only against loopback Supabase outside production with backend-only `SUPABASE_SECRET_KEY`. It uses confirmed synthetic identities for local testing and sends no invitation message. Existing login/read flows do not require that key; hosted activation/reset is separate work.

Expected failures: `400` invalid fields/key, `401` absent/invalid authentication, `403` disallowed role or missing/disabled application profile, `404` unavailable customer, `409` duplicate/conflicting creation and `503` unavailable dependencies/provisioning configuration. The app presents useful messages without rendering provider errors, SQL or tokens. Data responses use `Cache-Control: no-store`.

## Private reference enrollment

These routes implement reference collection and human review only. They do not perform an electronic match, liveness or transaction 2FA. All POST requests require a UUID `Idempotency-Key`; all commands return the current reference summary. An exact retry reconciles the same command, while changed effective input or a stale version returns `409`. Responses and private image streams use `Cache-Control: no-store`.

| Endpoint | Access and input |
| --- | --- |
| `GET /me/identity` | Active customer's own status, including absence of a case. |
| `GET /officer/customers/:id/identity` | Active officer, selected active customer. |
| `POST /me/identity/cases` | Own start/resume; `{ noticeVersion: "reference-demo-v1", acknowledged: true }`. |
| `POST /officer/customers/:id/identity/cases` | Assisted start/resume; same body, acknowledgement attributed to the officer. |
| `GET /identity/cases/:caseId` | Owner or officer; current summary for recovery. |
| `POST /identity/cases/:caseId/evidence` | Owner or officer; draft only. `{ expectedVersion, contentType, dataBase64 }`. JPEG/PNG, at most 10 MiB decoded input and 4096×4096 pixels; server decodes/re-encodes and strips metadata. |
| `GET /identity/cases/:caseId/evidence/:evidenceId` | Authorized current private preview as binary JPEG/PNG; expired, unavailable or another customer's evidence is not exposed. |
| `POST /identity/cases/:caseId/submit` | Owner or officer; `{ expectedVersion }`, ready draft evidence and acknowledgement required. |
| `POST /officer/identity/cases/:caseId/reviews` | Officer only; `{ expectedVersion, action, associationConfirmed, reason }`. Accept uses `action: "accept_reference"`, `associationConfirmed: true`, `reason: null`. Correction uses `action: "request_changes"`, `associationConfirmed: false`, and a reason of 5–500 characters. |

The summary contains `customerId`, `customerName`, `status`, nullable `caseId`/`version`/`revision`/`evidenceId`/`correctionReason`/`expiresAt`, `expired`, `notice: { version, text }` and `allowedActions`. Status is `not_started`, `draft`, `submitted`, `needs_changes` or `reference_accepted`. Expiry is represented by `needs_changes` plus `expired: true`. Allowed actions drive the UI but every command is re-authorized on the server.

Reference commands cannot set arbitrary state, object keys, match outcomes or customer roles. Evidence access requires backend-only Storage credentials; mobile-facing Supabase roles remain denied. Missing Storage configuration returns `503`; unavailable/unauthorized case IDs use `404`, disallowed route roles use `403`, invalid input uses `400`, oversized uploads use `413`, and state/version/retry conflicts use `409`. The upload route alone accepts a 14 MiB JSON envelope; this does not raise ordinary endpoint limits.

Reference acceptance expires with the case's seven-day demo lifetime. Requested display-name edits invalidate the reference atomically; phone/address changes do not. The maintenance command in [REFERENCE_FLOW.md](REFERENCE_FLOW.md) physically removes expired/abandoned files; no public cleanup route exists.

The gated local transfer and cash routes above can post synthetic transfers, deposits and withdrawals. The VNPay routes below implement sandbox checkout code; real provider acceptance and actual face comparison remain open. No endpoint may allow a client to set its financial balance, officer role or identity-verification result. AWS remains undecided.

## VNPay sandbox and labelled utility demos

Implemented code supports BR-04/10/11 and BR-14 links. All routes use `/api/v1` and `Cache-Control: no-store`. See [SANDBOX_PAYMENTS.md](SANDBOX_PAYMENTS.md) for fixtures, configuration, verification limits and the separate fulfillment boundary.

| Endpoint | Access and behavior |
| --- | --- |
| `GET /me/payments/configuration` | Customer; `{ enabled, services, highValueThresholdMinor, fulfillment }`. Catalogue is available while checkout is disabled. |
| `GET /me/payments` | Customer; latest 20 owned orders, newest first, `{ orders }`. Separate from bank-account transaction history. |
| `POST /me/payments/review` | Synthetic customer, configured sandbox, accepted reference and ready authenticator. Exactly `{ serviceId: "electricity" | "water" | "phone" }`. Amount and service details are server-owned. |
| `POST /me/payments/confirm` | Exactly `{ reviewToken, code }`; six-digit code, signed customer/session/service/amount/reference/factor binding, expiry and shared proof replay checks. Creates one authorized checkout, not a paid result. |
| `GET /me/payments/:id` | Owned order or security attempt; unauthorized IDs are 404. A valid pending checkout can be resumed after fresh sign-in without another TOTP confirmation. |
| `GET /payments/vnpay/ipn` | Public provider route; verifies raw-query signature, terminal, reference, order details/amount and authorization before row-locked result update. Returns VNPay `{ RspCode, Message }`; never returns customer information. |
| `GET /payments/vnpay/return` | Public static text instructing the customer to check Nene status. No query reflection, automatic redirect or payment mutation. |

Review returns `reviewToken`, `requestId`, `revision`, `service`, `amountMinor`, `currency` and `expiresAt`. First successful confirmation adds `purpose: "vnpay-checkout"`, fresh `accessToken`/`refreshToken`, `replay: false`, `order` and `checkoutUrl`. Flutter adopts the pair only through its bound session owner. Repeated confirmation returns status plus `replay: true`, never the pair. Uncertain post-verification failures return 503 and require status/sign-in recovery, not blind code retry.

An order contains `id`, `service`, `amountMinor`, `currency`, `state`, `createdAt`, `expiresAt`, nullable `paidAt`, and `fulfillment: "not_available"`. Payment state is `awaiting_payment`, `paid` or `failed`; a security attempt without an order can be `checking`, `rejected` or `unknown`. Checkout expiry alone does not prove failure. An authenticated late IPN can still record a result. Missing configuration returns 409 for new checkout, while catalogue and owned history remain readable.

No route accepts a real bill/subscriber number, client amount, arbitrary callback/provider URL, bank debit instruction or fulfillment status. A sandbox payment cannot settle a real bill, credit a phone or mutate a Nene account balance. These restrictions keep the approved demo within the PDF feature groups without adding a separate billing platform.

See [the source requirements](../REQUIREMENTS.md), [the scope boundaries](../SCOPE.md), and [the architecture](../DESIGN.md).
