# PDF scope and implementation audit

Reviewed **2026-11-05** against all three pages of [the assignment](../FinalProject_2026_2027.pdf), the [requirement register](../REQUIREMENTS.md), registered NestJS routes, Flutter destinations, migrations and feature evidence. This is a source/code/document review, not a new runtime acceptance test or security audit. No application behavior changed.

## Current decision and next task

The user has deferred **face comparison itself and provider selection**, not just AWS setup. Keep existing reference enrollment/review. Do not add a matcher, liveness SDK, OCR/document checks or provider resources now. eKYC and high-value verification remain unresolved requirements; this deferral does not establish that manual reference acceptance satisfies them. Retain the existing block on local financial amounts at or above 5,000,000 VND and separate transaction-bound TOTP.

**Next required feature: one payment-service integration (BR-10, PDF p. 2 Business 4).** It can progress independently of choosing a face matcher. Start with one provider-backed sandbox flow: backend-owned payment details, review and existing 2FA before initiating the financial action, provider checkout, trusted server confirmation, success/cancellation/failure, duplicate-result handling and customer-visible result/history. Preserve existing identity/amount restrictions for any supported Nene financial operation. A browser redirect alone must not mark payment successful.

Provider access, supported payment direction and sandbox acceptance must be settled for that integration. VNPay and Stripe are examples, not a requirement to integrate both. Do not equate an external checkout with a debit from a Nene account, a real deposit, bill fulfillment or an interbank transfer. No provider is selected in this audit; no account or charge is authorized. Until credentials are available, adapter tests and fixtures are only development evidence, not completed BR-10.

## Status by PDF feature group

"Implemented locally" below describes code and recorded checks; it does not mean full Android, hosted or lecturer acceptance.

| PDF requirement | Current implementation | Remaining requirement or acceptance gap |
| --- | --- | --- |
| Business 1: customer/officer profiles, permissions and requested edits (BR-01/02) | Shared sign-in, distinct role workspaces, local officer customer creation, customer contact edits and requested officer edits. | Usable hosted provisioning for the downloadable app and end-to-end Android acceptance. No public self-signup requirement. |
| Business 2: login, eKYC, biometric assistance and transaction 2FA (BR-03/04) | Reference capture/status/officer acceptance; authenticator setup/replacement/recovery; bound TOTP on local transfers/deposits/withdrawals. | eKYC method/acceptance and high-value verification unresolved; face comparison deferred. Extend 2FA to each later financial operation. |
| Business 3: checking/saving/mortgage information, savings rate/profit, officer rate edits, mortgage amount due (BR-05/06/07) | All three account views; savings annual rate/monthly estimate; officer rate update; stored monthly mortgage amounts and explicitly synthetic schedule provisioning. | Human/device acceptance and a documented demonstrable schedule policy. A real loan-origination or mortgage-collection system is not required by these clauses. |
| Business 3: history, deposits and withdrawals (BR-08) | Customer-owned monthly history; checking/saving deposits/withdrawals against an explicitly seeded local cash simulation. | Simulation acceptance and complete device/persistence evidence. This is not a live cash service. |
| Business 4: valid transfers and payment service (BR-09/10) | Local same-bank VND checking transfers below the threshold, with atomic balances/history and duplicate protection. | Other-bank transfer behavior and one actual payment-service integration. Their external/sandbox/simulation boundaries must stay distinct. |
| Business 5: electricity, water, phone top-up and purchase/booking (BR-11/12) | No working utility flow in the reviewed routes/screens. | All three named bill/top-up functions; clarify breadth of the flight/movie/hotel/e-commerce "or" list. No four-platform marketplace build. |
| Business 6: location, nearby offices and shortest walking route (BR-13) | No map/location/routing module in the reviewed app/backend. | User location, all nearby offices in declared coverage and walking route to the nearest office. |
| Business 7: intelligent activity-linked chat (BR-14) | No working chatbot module in the reviewed app/backend. | Conversational answers with valid activity links, including requested-month history. No autonomous payments. |
| Technical requirements (TR-01–08) | Flutter Android project, database persistence, documentation and recorded isolated checks. | Complete Android acceptance, usable Google Play release, final diagrams/report, UI evidence, video and course/team/template details. Local Edge preview is not Android/store acceptance. |

Code evidence: [registered controllers](../backend/src/app.module.ts), [Flutter destinations](../app/lib/ui/customer_workspace.dart), [account calculations](../backend/src/accounts/account-information.ts), [officer rate management](../backend/src/accounts/savings-policy.controller.ts), [database migrations](../infrastructure/supabase/migrations). Detailed evidence: [accounts](ACCOUNT_INFORMATION.md), [history](ACCOUNT_HISTORY.md), [transfers](LOCAL_TRANSFERS.md), [cash simulation](LOCAL_CASH.md), [reference enrollment](REFERENCE_FLOW.md), [authenticator management](AUTHENTICATOR_MANAGEMENT.md). No provider SDK for matching, payments, maps or chat appears in the reviewed dependency manifests.

## What is extra, and what should stop growing

No unrelated implemented business product was found in the reviewed routes/screens. Several chosen mechanisms go beyond the PDF's literal wording; they must not become new deliverables:

| Item | Classification and action |
| --- | --- |
| Authenticator replacement/backup-code recovery and session coordination | Additional support for the chosen 2FA mechanism, previously authorized and implemented. Keep working safeguards; do not build a broader account-recovery platform. |
| Reference notices, seven-day expiry, officer association and restricted storage | Implementation/privacy choices for the chosen reference flow, not PDF-mandated forms or periods. Keep them proportionate; no new compliance product. |
| Atomic posting, ownership checks, operation binding, retry protection and small audit records | Engineering support for required validity/permissions/2FA. Retain; "not explicitly named" does not make these unnecessary features. |
| Standalone **Try transfer confirmation - no money sent** flow and old authorization prototype | Authorized development experiments, not additional PDF outcomes. The preview still appears alongside the sending flow; it is a candidate to hide from the final customer journey after final UI review. No removal in this audit. The old prototype is not registered in AppModule. |
| Local cash balance, seeded accounts/funds and synthetic mortgage records | Test fixtures for required account/transaction demonstrations. Keep explicitly simulated and local; do not develop them into a wallet, cash-provider or loan product. |
| Browser/LAN runner, logo and iOS scaffold | User-requested development/presentation/future-compatibility support. Keep the runner local and uncommitted. No separate web bank or iOS release obligation. |
| AWS/matcher, advanced liveness, OCR/NFC and commercial KYC suite | Face comparison is deferred; the others are not required by name. None is installed or provisioned in the reviewed app. Do not add them as prerequisites for unrelated PDF work. |
| Loan applications, underwriting, credit scoring, automatic mortgage repayment and automatic interest crediting | Not explicitly required by the account-information clauses. Keep out of the delivery checklist unless a concrete interpretation is confirmed. Show required amounts/rates/profits under a small documented policy. |
| Cards, QR payments, analytics, notification center, support tickets, extra dashboards, full booking platforms | No implementation found; remain excluded. |

The 5,000,000 VND threshold, VND-only local flows, initial checking account and editable profile fields are project decisions, not PDF requirements. They can remain coherent demo rules without becoming new product scope.

## Planning corrections and remaining order

The prior immediate-next-task wording made comparison research look like a blocker for every remaining feature. It is now deferred. Planning references to "real mortgage policy", broad non-demo account administration and repayments must not imply production lending is an assignment prerequisite. Required mortgage amount display and usable account provisioning remain.

Some older documents describe TOTP/account/financial work as still absent; those are historical slice notes. The roadmap, design status and screen-map status now point to this audit and the implemented feature records. Do not repeat those old absence statements as current status.

After the payment integration, retain other-bank transfers, electricity/water/phone operations, the clarified purchase/booking coverage, branch walking navigation and activity-linked chat. Maps can proceed independently if payment-provider access delays that work. Complete eKYC decisions, Android/store acceptance and report/video evidence before claiming assignment completion. None of the seven feature groups is waived.

Validation: source/code traceability and documentation consistency review only. Shared `D:\Data\Downloads\Policies` remains unavailable; no policy compliance claimed. The source PDF/rubric and local-only launcher files were not changed. No provider resources, runtime processes or emulator were started.
