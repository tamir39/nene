# Nene project roadmap

This is the ordered checklist for completing Nene with Flutter, NestJS, and Supabase. All seven business feature groups stay in scope. Requirement IDs refer to [REQUIREMENTS.md](REQUIREMENTS.md); [SCOPE.md](SCOPE.md) explains the boundaries and unresolved assignment wording.

The internal submission target remains **29 November 2026**, ahead of the portal deadline at the start of **1 December**.

## Starting point

The app supports sign-in, distinct customer/officer workspaces, local officer customer creation, an initial zero-balance VND checking account, customer contact edits and requested officer edits. The private identity bucket is configured but has no upload or verification flow. The lighter Open pocket design is applied. Full assignment and hosted onboarding acceptance remain open. See [docs/CUSTOMER_FLOW.md](docs/CUSTOMER_FLOW.md) for the first-demo rules and [docs/SETUP.md](docs/SETUP.md) for verification.

## Build order

### 1. Define the screens and banking rules

Supports BR-01–BR-14 and TR-05.

- [ ] Review the proposed [customer/officer screen map](docs/SCREEN_MAP.md) and [three-screen UI direction](docs/UI_DIRECTION.md), then detail the remaining screens. The first study includes sign-in, customer home and officer workspace with loading/error/empty variants; financial confirmation, identity, map and chat layouts remain to draw. This item stays open until the broader design work is complete.
- [ ] Finish release assets from the selected [Open pocket logo direction](docs/BRANDING.md). The approved lighter palette, scalable logo, foundation screen styling and Android launcher/startup resources are applied. Final wordmark, small-size/single-color and launcher-mask review remain open; iOS assets are future work. This supports UI/report presentation (TR-05/TR-06), not an additional business feature.
- [ ] Finish banking rules: first-demo profile permissions, ownership and VND/zero-balance checking defaults are documented. Allowed deposits/withdrawals, savings calculations/rate changes, mortgage repayment convention and the high-value threshold remain open.
- [ ] Choose how eKYC, high-value identity checks, and transaction 2FA will work. Preserve officer-assisted identification; login alone does not cover these requirements.
- [ ] Resolve the lecturer's expectations for sandbox/simulated services and the purchase/booking categories before counting those flows as complete. Prove access to candidate providers early.

### 2. Complete customer and officer flows

BR-01, BR-02, BR-03, BR-04; TR-03.

- [x] Build distinct customer and officer navigation for the first flow in the same app. Later financial/map/chat destinations remain to implement.
- [x] Let an officer create a local synthetic customer identity and initial banking account, and make requested name/contact changes. Let customers view their own account/profile and edit phone/address. Keep public signup and client-selected roles disabled. See the local-only activation and retry limits in [CUSTOMER_FLOW.md](docs/CUSTOMER_FLOW.md).
- [ ] Design hosted customer activation/password recovery and sign-in email changes before enabling hosted provisioning. Secure session persistence is separate work.
- [ ] Implement private identity capture/upload, the chosen verification method, officer assistance, and high-value identity checks. A stored photo alone is not a completed verification flow.
- [ ] Implement transaction-bound 2FA before enabling money movements. Recheck the exact operation and reject missing, invalid, expired, reused, or mismatched verification as applicable to the chosen method.

### 3. Build accounts and secure transactions

BR-05, BR-06, BR-07, BR-08, BR-09; uses BR-03 and BR-04.

- [ ] Add checking, saving, and mortgage accounts with appropriate information views and checking/saving balances.
- [ ] Show savings rates and monthly monetary profit; allow authorized officers to change rates under the documented policy.
- [ ] Show mortgage amounts due for the selected monthly or two-week repayment convention.
- [ ] Implement deposits, withdrawals, same-bank transfers, account history, and transaction results through NestJS.
- [ ] Verify ownership, account rules, funds, required identity checks, and 2FA before posting. Keep balances/history consistent and prevent duplicate posting under retries or concurrent requests.

### 4. Connect payments and utilities

BR-09, BR-10, BR-11, BR-12; uses BR-04.

- [ ] Implement the other-bank transfer path and clearly identify its real, sandbox, or simulated behavior. Payment checkout alone does not cover interbank transfers.
- [ ] Integrate one payment provider, including verified callbacks, cancellation, failure, and duplicate-result handling.
- [ ] Complete electricity payments, water payments, and phone top-ups with confirmation, 2FA, result, and history.
- [ ] Implement the lecturer-confirmed purchase/booking coverage: flight tickets, movie tickets, hotel rooms, or e-commerce purchases. Keep all four alternatives unresolved until that breadth is clarified; do not silently assume one is sufficient.

Keep external fulfillment separate from payment success. Record sandbox/simulation limitations and any lecturer-approved exceptions. Reuse common payment components without building separate booking or commerce platforms.

### 5. Add branch navigation

BR-13.

- [ ] Show the user's location and all nearby offices on a map within the documented branch dataset and coverage area.
- [ ] Recommend the shortest walking path to the nearest office using the documented selection rule.
- [ ] Handle denied location permission and unavailable routes. Pins or driving directions alone do not complete this feature.

### 6. Add the activity-linked chatbot

BR-14.

- [ ] Build a chat screen with useful conversational answers and validated links to app activities.
- [ ] Support phone services, bills, and transaction-history requests that preserve a requested month.
- [ ] Keep account access authorized and route money-related requests through the ordinary confirmation and 2FA flow. The chatbot must not independently authorize payments.

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

**Select and document the identity-verification and transaction-2FA mechanisms, then implement enrollment and officer assistance.** Preserve high-value verification and 2FA for every financial operation. The first local officer-to-customer flow now provides the profile/account foundation; hosted activation, saving/mortgage account views and their calculation policies remain open. Do not enable deposits/transfers merely because checking balances can now be displayed.

Mark an item complete only when its behavior works, relevant checks pass, and evidence is recorded. Keep additional products, an iOS release, and unrelated banking features outside this assignment's scope. The original [PDF](FinalProject_2026_2027.pdf) and [marking workbook](Marking.xlsx) remain authoritative.
