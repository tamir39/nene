# Nene project roadmap

This is the ordered checklist for completing Nene with Flutter, NestJS, and Supabase. All seven business feature groups stay in scope. Requirement IDs refer to [REQUIREMENTS.md](REQUIREMENTS.md); [SCOPE.md](SCOPE.md) explains the boundaries and unresolved assignment wording.

The internal submission target remains **29 November 2026**, ahead of the portal deadline at the start of **1 December**.

Scope update, **2026-11-07**: the [movie-ticket demo](docs/MOVIE_TICKET_DEMO.md) adds the first BR-12 purchase category, with fictional offer selection and a read-only preview usable before VNPay setup. Configured checkout reuses the existing bound authenticator/provider flow; ticket fulfillment and full category acceptance remain open. The [local other-bank simulation](docs/LOCAL_INTERBANK.md) still awaits database/Auth and human checks. Face comparison/AWS stay undecided and high-value posting blocked. [VNPay and utility demos](docs/SANDBOX_PAYMENTS.md) still need credentials, callbacks and fulfillment acceptance. Branch testing remains deferred; no new business feature is added.

## Starting point

The app supports sign-in, distinct customer/officer workspaces, local officer customer creation, an initial zero-balance VND checking account, customer contact edits and requested officer edits. Private reference capture/status and officer acceptance/correction are implemented; actual identity matching remains open, while authenticator setup/recovery and local transfer-bound TOTP are implemented. The lighter Open pocket design is applied. Full assignment and hosted onboarding acceptance remain open. See [docs/CUSTOMER_FLOW.md](docs/CUSTOMER_FLOW.md), [docs/REFERENCE_FLOW.md](docs/REFERENCE_FLOW.md) and [docs/SETUP.md](docs/SETUP.md) for rules and verification limits.

## Build order

### 1. Define the screens and banking rules

Supports BR-01–BR-14 and TR-05.

- [ ] Review the proposed [customer/officer screen map](docs/SCREEN_MAP.md) and [three-screen UI direction](docs/UI_DIRECTION.md), then detail the remaining screens. The first study includes sign-in, customer home and officer workspace with loading/error/empty variants. Reference layouts are implemented with generated widget captures; transaction confirmation/2FA content and states are now mapped, while rendered financial, map and chat layouts remain to draw. This item stays open until the broader design work is complete.
- [x] Map customer reference enrollment/status and officer assistance/review to backend permissions, evidence access, state transitions and recovery. See [docs/IDENTITY_VERIFICATION.md](docs/IDENTITY_VERIFICATION.md) (simplified 2026-10-27) and the implemented [reference slice](docs/REFERENCE_FLOW.md). Accepting a reference photo does not complete eKYC.
- [ ] Finish release assets from the selected [Open pocket logo direction](docs/BRANDING.md). The approved lighter palette, scalable logo, foundation screen styling and Android launcher/startup resources are applied. Final wordmark, small-size/single-color and launcher-mask review remain open; iOS assets are future work. This supports UI/report presentation (TR-05/TR-06), not an additional business feature.
- [ ] Finish the minimum demo banking rules and acceptance: profile permissions, VND/zero-balance defaults, savings estimates and monthly mortgage display are documented. Confirm the demonstrated calculation/schedule policy and cash-simulation acceptance in [LOCAL_CASH.md](docs/LOCAL_CASH.md). Production lending, automated mortgage collection and interest crediting are not added requirements. The local financial threshold remains 5,000,000 VND (blocked at or above).
- [x] Define local demo notice, retention/deletion and officer confirmation defaults: explicit acknowledgement/association confirmation, seven-day access expiry and maintenance-driven physical deletion. See [REFERENCE_FLOW.md](docs/REFERENCE_FLOW.md). Hosted retention remains open; automated enrollment checks, liveness, OCR/NFC and native provider bridges are not prerequisites.
- [x] Compare simple server-side face comparison options against BR-03/BR-04 and the current stack. The 2026-11-05 [research](docs/IDENTITY_OPTIONS.md) recommends evaluating AWS CompareFaces first, with FPT FaceMatch and OpenCV alternatives. This completes research only, not provider selection or eKYC.
- [ ] **Deferred:** settle the eKYC/high-value verification method and whether to retain face comparison, then evaluate any selected implementation. AWS remains undecided; no accounts, costs or photo uploads are authorized. Local financial operations use TOTP and block amounts at or above the user-approved 5,000,000 VND threshold. Login and reference acceptance alone do not establish completed eKYC.
- [x] Plan the shared transaction review, conditional identity check, transaction 2FA, result and recovery flow. [TRANSACTION_FLOW.md](docs/TRANSACTION_FLOW.md) covers S02–S05, backend boundaries and acceptance targets; this completes planning only, not financial implementation. Supabase TOTP was subsequently integrated with transaction binding in the local transfer slice.
- [x] Run isolated Supabase TOTP compatibility probes with synthetic users. [TOTP_COMPATIBILITY.md](docs/TOTP_COMPATIBILITY.md) records working enrollment/verification, observed code/challenge replay and recovery limits. This completes the experiment, not BR-04 or factor selection; this experiment alone did not enable demo MFA; the later setup/management implementation does.
- [x] Prototype backend operation binding, atomic proof reservation, duplicate recovery, cancellation/supersession, expiry and one-time synthetic consumption. [AUTHORIZATION_PROTOTYPE.md](docs/AUTHORIZATION_PROTOTYPE.md) records 24 isolated checks, including real Supabase verification through two service instances. The service is unregistered, uses disposable records and moves no money; production integration and BR-04 remain open.
- [x] Plan customer authenticator enrollment, replacement/lost-access recovery and session handoff before app integration. [AUTHENTICATOR_LIFECYCLE.md](docs/AUTHENTICATOR_LIFECYCLE.md) recommends TOTP plus provider-native recovery codes subject to compatibility gates. Recovery codes permit replacement only; ordinary officer edits cannot reset MFA. This completes planning, not implementation or factor selection.
- [x] Run isolated recovery-code and session-handoff probes. [RECOVERY_SESSION_COMPATIBILITY.md](docs/RECOVERY_SESSION_COMPATIBILITY.md) records working provider recovery/replacement, signed password timing, 32 Dart SDK tests and five two-tab Edge observations. The experiment is complete; browser handoff safety did not pass because late peer broadcasts bypass the local guard. This does not complete BR-04 or enable demo MFA.
- [x] Prove isolated browser session ownership and refresh coordination before customer integration. [SESSION_COORDINATION_PROTOTYPE.md](docs/SESSION_COORDINATION_PROTOTYPE.md) records independent memory-only tab sessions, delayed logout/account-switch protection, serialized handoff/refresh and usable real-provider refreshes. This passes the isolated coordinator gate; production Auth integration, backend lifecycle rules and BR-04 acceptance remain open.
- [ ] Resolve the lecturer's expectations for sandbox/simulated services and the purchase/booking categories before counting those flows as complete. Prove access to candidate providers early.

### 2. Complete customer and officer flows

BR-01, BR-02, BR-03, BR-04; TR-03.

- [x] Implement customer authenticator replacement and native backup-code recovery, including one-time code display, restricted lifecycle states, fresh-proof resume and final sign-out. [AUTHENTICATOR_MANAGEMENT.md](docs/AUTHENTICATOR_MANAGEMENT.md) records backend/Flutter and real-provider evidence, supported interruptions and blocked cases. Human Edge/native acceptance remains open; this is BR-04 support, not completed transaction authorization.

- [x] Build distinct customer and officer navigation for the first flow in the same app. Later financial/map/chat destinations remain to implement.
- [x] Let an officer create a local synthetic customer identity and initial banking account, and make requested name/contact changes. Let customers view their own account/profile and edit phone/address. Keep public signup and client-selected roles disabled. See the local-only activation and retry limits in [CUSTOMER_FLOW.md](docs/CUSTOMER_FLOW.md).
- [ ] Design hosted customer activation/password recovery and sign-in email changes before enabling hosted provisioning. Secure session persistence is separate work.
- [ ] Complete human/native acceptance of the implemented customer Transaction security flow: setup/status, safe replacement, tested recovery codes and explicit blocked/help states. Keep sessions memory-only and invalidate obsolete authorization/session bindings when a factor changes. Enrollment/recovery never authorizes a payment.
- [x] Implement provider-neutral selection/capture of one reference photo, private storage, enrollment status and officer assistance/review. The officer accepts the reference or requests a correction; the UI calls this **Reference accepted**. Automated checks use generated images; web user acceptance and native camera/device validation remain open.
- [ ] **Deferred method decision:** complete the later high-value identity check under the chosen eKYC approach. The earlier face-comparison design remains a candidate, not the next task. Keep checks tied to the operation and reject missing, failed or unavailable evidence; document assurance limits.
- [ ] Extend the implemented local-transfer transaction-bound 2FA to all remaining money movements. Recheck the exact operation and reject missing, invalid, expired, reused, or mismatched verification as applicable to the chosen method.
- [x] Implement the customer same-bank review and transaction-bound authenticator check with an explicit not-sent result. [TRANSACTION_CONFIRMATION.md](docs/TRANSACTION_CONFIRMATION.md) records signed review/session binding, shared replay reservations, active factor/revision checks, cancellation and test evidence. This is a confirmation preview; financial authorization consumption and BR-04 acceptance remain open.

### 3. Build accounts and secure transactions

BR-05, BR-06, BR-07, BR-08, BR-09; uses BR-03 and BR-04.

- [ ] Complete acceptance of checking, saving and mortgage views with checking/saving balances. Account-type information views and [local synthetic savings/mortgage provisioning](docs/DEMO_ACCOUNT_PROVISIONING.md) are implemented. Demonstrate usable account provisioning for the submitted app; do not add a general banking-account administration product.
- [ ] Show savings rates and monthly monetary profit; allow authorized officers to change rates under the documented policy. Backend and Flutter support now exist with isolated database/widget evidence; full app acceptance remains open.
- [ ] Complete acceptance of the mortgage amount due under the documented monthly convention. Schedule reads and local 0% sample provisioning are implemented. Confirm the demo calculation/schedule policy and human/native behavior; loan issuance and repayment processing are not prerequisites for this display requirement.
- [x] Implement customer-owned, read-only account history with month filtering and pagination through NestJS and Flutter. [ACCOUNT_HISTORY.md](docs/ACCOUNT_HISTORY.md) records checks and limits; history stays empty until a gated local transfer, deposit or withdrawal is posted. Human Edge/native acceptance remains open.
- [x] Implement local same-bank synthetic transfers below 5,000,000 VND with accepted reference, bound TOTP, atomic balances/history, duplicate protection and receipt recovery. See [LOCAL_TRANSFERS.md](docs/LOCAL_TRANSFERS.md). This is bounded demo evidence, not full BR-03/04/08/09 acceptance.
- [x] Implement bounded local checking/saving deposits and withdrawals with review, reference/TOTP checks, atomic cash/account/history updates and typed receipt recovery. See [LOCAL_CASH.md](docs/LOCAL_CASH.md). Mortgage repayments and real cash services are not implemented by this slice.
- [ ] Complete human/native validation and funding/sandbox acceptance for deposits, withdrawals and same-bank transfers. Local implementation evidence alone does not complete all BR-04/08/09 requirements.
- [ ] Verify ownership, account rules, funds, required identity checks, and 2FA before posting. Keep balances/history consistent and prevent duplicate posting under retries or concurrent requests.

### 4. Connect payments and utilities

BR-09, BR-10, BR-11, BR-12; uses BR-04.

- [ ] Validate the implemented [other-bank transfer simulation](docs/LOCAL_INTERBANK.md): separate fictional recipients, existing demo funds, bound TOTP and atomic debit/credit/receipt/history. Database/Auth, Edge/native and lecturer acceptance remain open; no real interbank network is connected. Payment checkout remains a separate flow.
- [x] Compare simple payment providers against BR-10 and the existing app. [Payment research](docs/PAYMENT_OPTIONS.md) evaluated VNPay, Stripe and MoMo; the user subsequently selected VNPay PAY sandbox. Test credentials/callback setup and implementation remain open in the [setup record](docs/VNPAY_SANDBOX_SETUP.md); face comparison stays deferred.
- [ ] Complete provider-backed acceptance of one payment integration. The [VNPay sandbox adapter, bound TOTP, checkout, IPN and payment history](docs/SANDBOX_PAYMENTS.md) are implemented; actual credentials, callback isolation/delivery and success/failure/cancellation/retry evidence remain pending. Checkout stays disabled by default.
- [ ] Complete electricity payments, water payments, and phone top-ups with confirmation, 2FA, result, and history. User-approved fixed demo services and payment-status screens are implemented. No real bill settlement or phone credit occurs; biller integration or lecturer acceptance of simulation remains unresolved.
- [ ] Complete the lecturer-confirmed purchase/booking coverage. [Movie-ticket demo selection/preview and gated sandbox checkout](docs/MOVIE_TICKET_DEMO.md) are the first BR-12 slice. No real ticket/reservation is issued. Flight, hotel and e-commerce coverage, fulfillment and whether one category is sufficient remain unresolved; no waiver is assumed.

Keep external fulfillment separate from payment success. Record sandbox/simulation limitations and any lecturer-approved exceptions. Reuse common payment components without building separate booking or commerce platforms.

### 5. Add branch navigation

BR-13.

- [x] Implement the [demo branch map](docs/BRANCH_NAVIGATION.md): fictional Nene offices near TDTU, one-shot location, all catalog offices within 5 km, explicit demo starting point and text list. Database runtime/human acceptance remain pending.
- [x] Implement the pedestrian shortest-distance route to the geographically nearest office through NestJS. A synthetic TDTU route succeeded against Valhalla; production provider arrangements remain open.
- [x] Handle permission denial, no nearby offices, map errors and unavailable routes without fabricating a route.
- [ ] Complete database integration, human Edge and Android location/route checks. The demo fallback and automated fixtures do not replace real-location acceptance for BR-13.

### 6. Add the activity-linked chatbot

BR-14.

- [x] Implement the [bounded activity assistant](docs/ASSISTANT.md): English/Vietnamese requests, month clarification, plain-text answers and validated links to existing history/financial forms. Conversational adequacy and human acceptance remain open.
- [x] Preserve an explicitly requested history month through customer-owned account selection and the history screen; resolve relative months using UTC+07.
- [x] Keep financial links in the ordinary account/form/review/2FA flows; chat cannot post or authorize transactions. Clear its memory-only conversation on session changes.
- [ ] Complete phone/bill service acceptance. Assistant destinations now open the labelled [demo services](docs/SANDBOX_PAYMENTS.md), with separate review/TOTP and no automatic checkout. Actual fulfillment, provider evidence and full BR-14 acceptance remain open.
- [ ] Complete human Edge/Android assistant testing when the user is ready; retain proof of the required linked activities for the report/demo.

### 7. Verify and submit the complete app

TR-01–TR-08 and acceptance evidence for every BR requirement.

- [ ] Test the complete customer/officer journeys on Android, including persistence, denied access, calculation errors, repeated requests, provider failures, and denied camera/location permissions where relevant.
- [ ] Refine UI consistency, readable amounts, accessible controls, feedback, and error recovery across every required feature.
- [ ] Finish the faculty-format report with required team details, architecture rationale, class/ER/use-case/component/infrastructure diagrams, code/technology explanations, all UI evidence, table of contents, and references.
- [ ] Record a demo covering both roles and all seven feature groups.
- [ ] Complete Google Play availability and verify that reviewers/users can install and use the app through the documented provisioning/demo path. A debug APK or internal test does not replace TR-04 without lecturer agreement.

## Start alongside development

- [ ] Obtain the faculty report template and maintain diagrams, screenshots, test results, and demo notes as each feature is built.
- [ ] Check Play Console account verification and account type early. If the new-personal-account rule applies, plan the required closed test with at least 12 testers continuously opted in for 14 days, then apply for production access. App review follows separately; approval dates are not guaranteed. See Google's [testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en).
- [ ] Prepare hosting, final app identifiers, release signing, store materials, privacy/data declarations, and reviewer access. Describe Nene's educational/synthetic behavior accurately and resolve the applicable account/declaration treatment before submission; see Google's [financial features guidance](https://support.google.com/googleplay/android-developer/answer/13849271?hl=en). Cloud provisioning, costs, and publication remain separate user decisions.

Maps can progress once navigation and provider access are settled. Chatbot links depend on stable activity destinations and history filters. Every financial flow depends on the security and transaction checks above. These dependencies determine the build order; they do not require waiting for every earlier screen to be polished.

## What we should do next

**Test authenticator replacement and recovery in Edge:** run `run.bat stop`, then `run.bat` to recreate the owned local Auth container with native recovery enabled while preserving database data. Follow [AUTHENTICATOR_MANAGEMENT.md](docs/AUTHENTICATOR_MANAGEMENT.md#verification-and-local-demo): privately save backup codes first, then test current-factor replacement and lost-authenticator recovery with a synthetic customer. The app signs out everywhere on completion. No Android emulator is needed.

**Test transaction-bound confirmation in Edge:** after restarting your user-run `run.bat`, open **Try transfer confirmation · no money sent** under a checking account. Enter another existing synthetic customer's checking account number and an amount, review it and use a fresh authenticator code. The result must say **Transfer not sent**. Zero balances show insufficient funds while allowing this security-only test. See [TRANSACTION_CONFIRMATION.md](docs/TRANSACTION_CONFIRMATION.md).

**Test the local sending flow in Edge:** follow [LOCAL_TRANSFERS.md](docs/LOCAL_TRANSFERS.md#local-demo) to apply the migration, explicitly prepare two synthetic checking accounts and restart the user-run launcher. Send a small amount, verify both balances/history, and check the receipt after signing in again. The earlier confirmation preview still sends nothing.

**Test deposits and withdrawals in Edge:** follow [LOCAL_CASH.md](docs/LOCAL_CASH.md#test-in-the-user-run-edge-demo) to prepare the one-time simulated cash source, restart the user-run launcher and test both checking/saving actions, balances and history. Real cash services and lecturer acceptance of simulation remain open.

**Current slice: movie-ticket demo (BR-12).** [MOVIE_TICKET_DEMO.md](docs/MOVIE_TICKET_DEMO.md) adds two fictional one-ticket offers, a read-only preview that works without VNPay, and the ordinary configured review/TOTP/checkout/status flow with stored offer snapshots. The user can test selection/preview in Edge later. Actual payment, fulfillment and category acceptance stay open. [Local other-bank transfers](docs/LOCAL_INTERBANK.md) retain their pending runtime checks.

**Branch-map testing is deferred at the user's request.** [BRANCH_NAVIGATION.md](docs/BRANCH_NAVIGATION.md#verification-and-local-test) retains the database, human Edge and Android checks. The user approved fictional Nene offices near TDTU; they are not another bank's branches. No deferred check is marked passed by chatbot work.

**Next acceptance work:** when Docker is available, run the isolated interbank and updated payment database/Auth checks, then test the other-bank flow and movie preview in the user-started Edge app. Once VNPay credentials and a public hostname are available, validate the restricted callback endpoint before sandbox checkout/IPN. Keep fulfillment and lecturer acceptance separate. Face comparison remains undecided and high-value posting stays blocked. Clarify remaining purchase/booking coverage; Android/store and report/video work also remain required.

The user selected **VNPay PAY sandbox hosted checkout on 2026-11-05** after the [provider comparison](docs/PAYMENT_OPTIONS.md). The [setup record](docs/VNPAY_SANDBOX_SETUP.md) lists the user's test registration, terminal ID/signing secret and a restricted HTTPS IPN/return endpoint. Account/domain access, credentials and actual callback reachability remain pending; the user has no ngrok account or public URL yet. Current LAN-only `run.bat` does not supply an internet callback. Face comparison remains undecided.

Customer history and all three account views are also ready for user acceptance. Month filtering and ownership checks are implemented; no sample transactions have been inserted. See [ACCOUNT_HISTORY.md](docs/ACCOUNT_HISTORY.md) for the PDF link and verification boundary.

**Test all three account views in the user-started Edge demo.** Officers can now use Find a customer → Add demo account to create zero-balance savings and a labelled synthetic mortgage schedule. Follow [DEMO_ACCOUNT_PROVISIONING.md](docs/DEMO_ACCOUNT_PROVISIONING.md). This supports BR-02/05/06/07 without a deposit or loan disbursement; do not mark financial operations complete.

For customers without an authenticator, begin with [first-time setup](docs/AUTHENTICATOR_SETUP.md), then create backup codes in the management flow. Human authenticator and full browser/API acceptance remain open. Shared purpose/revision checks now protect the confirmation preview; the local sending path now enforces them at atomic financial consumption.

The [backend prototype](docs/AUTHORIZATION_PROTOTYPE.md) demonstrates operation binding, cross-instance replay prevention and safe recovery with synthetic records. It is not connected to app routes or real accounts. Keep the [transaction plan](docs/TRANSACTION_FLOW.md)'s intent-storage interpretation, first-transfer rules and high-value policy explicit; temporary prototype records do not resolve the lecturer interpretation. Posting outside the explicitly gated synthetic local transfer policy remains disabled.

The user can review the implemented [reference flow](docs/REFERENCE_FLOW.md) in the Edge web demo alongside this work by starting local `run.bat`. Android Studio/emulator launch is excluded unless requested again. AWS and the face-comparison implementation remain undecided.

The later high-value path remains blocked pending the eKYC method/acceptance decision; face comparison itself is deferred. The demo threshold is 5,000,000 VND and TOTP is enforced on every local transfer, deposit and withdrawal. Keep simulation and replay/spoof limits explicit. Hosted usability and human/device acceptance remain open; saving/mortgage views and demo calculations are implemented. Do not expand those display requirements into production lending or automatic interest/repayment systems.

Mark an item complete only when its behavior works, relevant checks pass, and evidence is recorded. Keep additional products, an iOS release, and unrelated banking features outside this assignment's scope. The original [PDF](FinalProject_2026_2027.pdf) and [marking workbook](Marking.xlsx) remain authoritative.
