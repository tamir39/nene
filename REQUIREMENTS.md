# Requirements and assessment

Status: source audit retained; implementation status updated 2026-10-20. All three PDF pages and the rubric were reviewed. Required outcomes, confirmed choices, example mechanisms, and proposed acceptance evidence are distinguished below. The first local officer/customer flow is implemented; full assignment acceptance remains open.

## Sources

- [FinalProject_2026_2027.pdf](FinalProject_2026_2027.pdf), pages 1-3: Ton Duc Thang University, Faculty of Information Technology, Mobile Apps Development final project.
- [Marking.xlsx](Marking.xlsx), worksheet `Marking`, rows 4-18: evaluation criteria and weights. Criteria are written in Vietnamese.

For clause-by-clause scope, examples, ambiguity handling, exclusions, and demonstration boundaries, read [SCOPE.md](SCOPE.md). This file is the compact requirement register; the original PDF/workbook remain authoritative assignment sources.

The original PDF and workbook do not set a submission date, app framework, Android SDK versions, bank/app name, high-value threshold, provider credentials, or a policy for accepting simulated integrations. Later user-confirmed inputs are recorded below; the remaining items are open.

### Confirmed planning inputs

On 2026-10-13, the user supplied a submission-portal screenshot (`codex-clipboard-5a7bbee5-1773-4f4a-8297-aecc5541319b.png`) showing the due date as **Tuesday, 1 December 2026, 12:00 AM**. This is midnight at the start of 1 December, so submission must be completed before that boundary on Monday, 30 November. The screenshot does not display a timezone; planning uses Asia/Bangkok (UTC+7) provisionally. The portal's displayed due date remains authoritative.

On 2026-10-13, the user confirmed free technology-stack choice and selected **Flutter/Dart + a single NestJS/TypeScript API + Supabase-hosted PostgreSQL, Supabase Auth, and private Supabase Storage**. These are implementation decisions, not technologies mandated by the assignment. The screenshot/user updates resolve the previously unknown deadline, framework restriction, and core stack selection; the original PDF/workbook remain unchanged. Actual team size and member experience remain unknown.

Banking reads and writes pass through the NestJS API, with persistence in PostgreSQL. The app uses Supabase Auth, scoped API access using `pg`, Flutter ChangeNotifier state, and private Supabase Storage configuration. The detailed access and future file-transfer design is in [DESIGN.md](DESIGN.md). API hosting, eKYC and transaction-2FA mechanisms, and external service providers remain open. Selecting managed authentication does not itself satisfy eKYC or transaction-bound 2FA.

On 2026-10-15, the user authorized the local base project. On 2026-10-20 the first officer/customer flow adds local customer creation, an initial zero-balance VND checking account, own phone/address edits and requested officer name/contact edits. These are provisional demo rules, not PDF prescriptions; see [docs/CUSTOMER_FLOW.md](docs/CUSTOMER_FLOW.md). Hosted activation, saving/mortgage accounts, money movements, eKYC, transaction 2FA, utilities, maps, chatbot and submission deliverables remain incomplete. No cloud or store deployment has occurred. See [docs/SETUP.md](docs/SETUP.md) for exact checks and limitations; the acceptance-evidence column below describes targets, not blanket completion claims.

The user additionally wants flexibility for Android and iOS and easier future technology upgrades. These are user design goals. The brief requires Android; an iOS release by the assignment deadline has not been requested or established.

On 2026-10-27, the user directed a simpler identity flow: officer-assisted private reference enrollment, an actual server-side one-to-one face comparison for high-value activity, and separate transaction 2FA. AWS remains undecided. Liveness SDKs, provider-specific native bridges, document OCR/NFC and commercial KYC are not baseline prerequisites. [docs/IDENTITY_VERIFICATION.md](docs/IDENTITY_VERIFICATION.md) separates reference acceptance from a passed electronic check and records spoofing limits. This is a project design direction, not an implemented feature, lecturer-approved exception or waiver of BR-03/BR-04. The exact matching implementation and eKYC acceptance expectations remain open.

## Technology constraints verified against the PDF

| Topic | Source wording and classification | Decision implication |
| --- | --- | --- |
| Platform | Android is required (p. 3, Technical 1). The Apple App Store mention on p. 1 is background context. | Flutter selected to deliver Android. Cross-platform support serves the user's additional goal. |
| Framework/language | No framework or programming language prescribed. User also confirmed free stack choice. | Flutter/Dart selected by the user; it is not an assignment mandate. |
| Database | Database storage required; device SQLite allowed; cloud storage preferred (p. 3, Technical 2). | Supabase-hosted PostgreSQL selected. It fits the cloud preference, as an interpretation of the stated requirement. |
| Firebase | Given as an example of a cloud service (p. 3, Technical 2). | Firebase, Firestore, Firebase Authentication, Storage, and Functions are not a mandatory product bundle. |
| Backend/deployment | No backend framework, API style, serverless model, or separate server prescribed. | A single NestJS/TypeScript API selected for banking operations. API hosting remains open; no additional services or microservices are implied. |
| Identity and 2FA | Login/eKYC and transaction 2FA required. Face-photo enrollment/high-value verification and OTP are example mechanisms (p. 2, Business 2). | Preserve identity verification and high-value verification intent; choose and document the mechanisms. No liveness vendor, face algorithm, or OTP channel specified. |
| Payment service | Integration required; VNPay and Stripe are examples (p. 2, Business 4). | Select a supported service. Neither both named providers nor a particular provider is mandated. |
| Maps and AI | Walking directions and intelligent activity-linked chat required (p. 2, Business 6-7). | No map, route, AI vendor, or model prescribed. Plain map pins and generic chat alone do not cover the requirements. |
| Release | Google Play availability required (p. 3, Technical 3). | Choosing Flutter does not remove the store submission requirement or add an iOS release requirement. |
| Design evidence | Explain choices and provide class/ER/use-case/component diagrams and implementation/UI documentation (p. 3, Technical 4). | An ER diagram does not mandate SQL, and architecture marks do not prescribe a framework. |

The PDF leaves product choices to the team; a specific stack is not implied by its example brands. The unresolved items are implementation policies (such as interest formulas and the high-value threshold), external integration access, acceptance of simulations/sandboxes, and the exact breadth of the purchase/booking examples.

## Business requirements

The acceptance evidence column is a proposed way to demonstrate each requirement; it does not change the brief.

| ID | Required behavior | Source | Proposed acceptance evidence |
| --- | --- | --- | --- |
| BR-01 | Support customers and bank officers with different interfaces and permissions. | PDF p. 1, item 1 | Both roles demonstrated; unauthorized actions rejected by the backend. |
| BR-02 | Officers create customer accounts and modify customer data on request; customers view and modify their own banking information. | PDF p. 1, item 1 | Account creation and profile changes demonstrated with explicit editable-field rules. |
| BR-03 | Provide a login screen and eKYC to identify customers/users. Officers can assist with biometric identification. Face scanning/upload and using that image for high-value verification are the brief's example approach. | PDF p. 2, item 2 | Demonstrate enrollment and high-value verification behavior, with the chosen method, actor coverage, and threshold documented. A specific face algorithm or liveness product is not prescribed. |
| BR-04 | All transactions pass 2FA before being persisted in the system. OTP is given as an example. | PDF p. 2, item 2 | Missing or invalid second-factor verification cannot post a financial transaction. If OTP is chosen, cover wrong, expired, reused, and transaction-mismatched codes. |
| BR-05 | Support checking, saving, and mortgage accounts with different information views. Show checking/saving balances. | PDF p. 2, item 3 | All three account types demonstrated with the appropriate fields. |
| BR-06 | Show saving rates and monthly profits; officers can modify rates according to bank policy. | PDF p. 2, item 3 | Show both the customer-visible rate and monthly monetary profit, plus an officer rate change; document calculation and effective-date policy. |
| BR-07 | Show mortgage payment amounts due monthly or every two weeks. | PDF p. 2, item 3 | Demonstrate correct amounts and schedules for the chosen frequency/frequencies. Supporting both is a scope choice; the brief does not explicitly require both. |
| BR-08 | Show account transaction history and allow deposits and withdrawals. | PDF p. 2, item 3 | History and both money operations demonstrated with validation and 2FA. |
| BR-09 | Verify transactions are allowed and valid before database persistence. Retain both same-bank and other-bank transfer destinations as the conservative reading of the source's "or" wording. | PDF p. 2, item 4 | Authorization/policy and business-validity checks, valid transfer, invalid recipient, insufficient funds, duplicate request, and external-bank outcome demonstrated. |
| BR-10 | Integrate a payment service such as VNPay or Stripe. | PDF p. 2, item 4 | Provider-backed sandbox payment and verified server callback shown; cancellation/failure handled. Provider and accepted environment remain open. |
| BR-11 | Pay electricity and water bills and top up a phone account. | PDF p. 2, item 5 | All three flows shown with confirmation, 2FA, result, and history. |
| BR-12 | Buy flight/movie tickets, book hotel rooms, or pay for products on an e-commerce platform. | PDF p. 2, item 5 | Lecturer-confirmed coverage demonstrated. The wording leaves unclear whether one example or all named activities are expected. |
| BR-13 | Locate the user, show the user and all nearby bank offices on a map, and recommend the shortest walking path to the nearest office. | PDF p. 2, item 6 | User marker, all qualifying branch markers within the documented coverage/radius, nearest-office selection, walking route, and permission-denied behavior shown. |
| BR-14 | Provide a chat screen where users ask an intelligent chatbot questions and receive answers with links to requested financial activities, including phone payments, bills, and transactions of the month. | PDF p. 2, item 7 | Natural-language examples open correct app destinations, preserve a requested month filter, and preserve authorization. |

## Technical and submission requirements

| ID | Requirement | Source | Evidence needed |
| --- | --- | --- | --- |
| TR-01 | Work in a team of 2-3 members. | PDF p. 3, item 1 | Team list and responsibilities. |
| TR-02 | Deliver an Android app covering all business requirements. | PDF p. 3, item 1 | Installable build and complete feature demonstration. |
| TR-03 | Store all application data in a database. SQLite on-device is allowed; a database on a cloud service is preferred, with Firebase as an example. | PDF p. 3, item 2 | Database design and persistent behavior. The selected private identity-file storage and proposed access design are discussed in `DESIGN.md`. |
| TR-04 | Deploy to Google Play so users can download and use it on their smartphones. | PDF p. 3, item 3 | Actual store availability. A locally installed APK or internal test alone is not equivalent without lecturer agreement. |
| TR-05 | Report analysis/design principles, patterns, practices, class diagrams, ER diagrams, use cases, and component/infrastructure solution diagrams as applicable. | PDF p. 3, item 4 | Final diagrams matching the implementation and explanations of design choices. Required class/ER/use-case evidence must not be treated as optional. |
| TR-06 | Explain implementation structure and technologies; present all UI functionality. | PDF p. 3, item 4 | Code-structure explanation and feature/screens evidence. |
| TR-07 | Provide a feature demo video. | PDF p. 3, item 5 | Video covering both roles and the required functionality. |
| TR-08 | Follow the faculty report format, provide an index/table of contents, correct spelling, coherent presentation, and references. | Marking rows 17, C17:E17 | Faculty template and reviewed final report. The template has not been supplied. |

## Marking breakdown

| Criterion | Maximum points | Workbook cells |
| --- | ---: | --- |
| Architecture and technology rationale | 1.0 | A4:B4 |
| Class diagrams | 1.0 | A6:B6 |
| UI quality | 1.0 | A7:B7 |
| Database design | 1.0 | A8:B8 |
| User profiles | 1.0 | A10:B10 |
| Security requirements | 1.0 | A11:B11 |
| Account management | 0.5 | A12:B12 |
| Transaction management | 1.0 | A13:B13 |
| Utilities | 0.5 | A14:B14 |
| Navigation | 0.5 | A15:B15 |
| Chatbot | 0.5 | A16:B16 |
| Report/demo presentation | 1.0 | A17:B17 |
| **Total** | **10.0** | B18 |

Architecture plus analysis/design is 4 points, features are 5 points, and report/demo presentation is 1 point. The top rubric band expects clear, complete design, correct class/database relationships, a professional UI, and stable, complete features. Weights help allocate effort; they do not make any PDF requirement optional.

### Workbook issues found during review

The maximum-score formulas reconcile to 10. The self-assessment formulas appear inconsistent with the labeled criteria:

- `F9 = SUM(F10:F15)` excludes the chatbot score in `F16`. A likely correction is `SUM(F10:F16)`.
- `F18 = SUM(F3,F5,F9,F17)` references `F3`, which is blank, rather than the architecture self-assessment in `F4`. A likely correction is `SUM(F4,F5,F9,F17)`.

Both formulas currently have cached zero results, so the omission is not visible in a populated total. The workbook has not been edited. Confirm with the lecturer before treating a corrected version as an official assessment artifact.

## Confirmed decisions and remaining questions

| Topic | Current position | Needed clarification |
| --- | --- | --- |
| Framework | Flutter/Dart confirmed by the user on 2026-10-13. The base uses built-in ChangeNotifier. Android delivery remains required; future iOS compatibility is a user goal. | Platform/plugin compatibility checks as features are added; iOS build testing requires macOS. |
| Backend and managed services | A single NestJS/TypeScript API, Supabase-hosted PostgreSQL, Supabase Auth, and private Supabase Storage confirmed by the user on 2026-10-13. The local base uses `pg` with SQL migrations. | API hosting, provider access, and budget. Local scaffolding does not authorize paid services or deployment. |
| Team and schedule | Brief requires 2-3 people; actual team unknown. Portal deadline: 1 December 2026, 12:00 AM. Proposed internal submission target: 29 November. | Names, capacity, portal timezone, and agreed intermediate milestones. |
| Branding and language | Working brand is Nene; Open pocket logo direction and teal + apricot palette selected on 2026-10-19. See [docs/BRANDING.md](docs/BRANDING.md). | Final public/store name, production artwork, typography, and Vietnamese/English UI/report expectations. |
| Integration scope | Sandbox-first implementation is proposed. | Lecturer acceptance of sandbox payment, simulated interbank/biller/booking services, and permitted providers. |
| eKYC and high-value checks | eKYC required; the paragraph describes biometric assistance and a face-photo example for high-value verification. | Chosen verification method, high-value threshold, and any lecturer expectation beyond the text. No specific liveness service is prescribed. |
| Transaction 2FA | Required for all transactions; OTP is our proposed mechanism. | Chosen second factor and delivery/verification method. |
| Account rules | Three types required. | Allowed deposits/withdrawals per type, interest/rounding rules, rate effective dates, mortgage formulas and frequencies. |
| Utility breadth | Bills and phone top-up are explicit. | Whether BR-12 requires one purchase/booking example or all named categories. |
| Maps | Location, branches, and walking-route recommendation required. | City/branch dataset and route provider. |
| Play deployment | Required by brief. On 2026-10-13, the user reported an existing Google console account with identity verification pending; understood in this discussion to mean Google Play Console. Account status has not been inspected directly. | Verification completion, personal/organization account type, release timing, and whether public publication is required for grading. |
| Report | Faculty format required by rubric. | Official report template. |
| Shared policies | Supplied path unavailable at review time. | Current policy bundle location, if applicable. |
