# Nene assignment scope

Status: detailed source audit retained; local implementation status updated 2026-10-20. The first local officer/customer flow extends login with initial account creation and permitted profile edits. Full assignment acceptance remains open. No lecturer-approved exceptions have been supplied.

## Scope statement

Deliver one Android mobile banking application covering every business requirement group in the assignment, with its database, required report/diagrams, Google Play availability, and demo video. Preserve future iOS compatibility where practical, as requested by the user. Engineering mechanisms support the required flows; they do not create additional product deliverables.

On 2026-10-13, the user selected **Flutter/Dart + a single NestJS/TypeScript API + Supabase-hosted PostgreSQL, Supabase Auth, and private Supabase Storage**, then authorized the local base on 2026-10-15. The base implements email/password login, server-controlled profile reads, and local database/private storage configuration. It uses Flutter ChangeNotifier and NestJS `pg` access with SQL migrations. These are implementation choices supporting BR-01/BR-03 and TR-03, not additional product requirements or completion of those requirements. Banking data access uses NestJS. API hosting, external providers, eKYC/transaction-2FA mechanisms, financial policies, and integration realism remain open.

The [first customer flow](docs/CUSTOMER_FLOW.md) adds local officer provisioning, one zero-balance checking account and permitted customer/officer profile edits. It adds no financial commands or fake completed feature screens. Identity upload/verification, saving/mortgage management, transactions, utilities, walking navigation, chatbot and submission evidence remain future work. Its generated iOS shell is preparation for future compatibility, not an extra release deliverable. [docs/SETUP.md](docs/SETUP.md) records current checks and limitations.

On 2026-10-27, the user approved simplifying identity work to private reference enrollment with officer assistance/review, followed by actual server-side one-to-one comparison for high-value activity and separate transaction 2FA. [The minimum flow](docs/IDENTITY_VERIFICATION.md) is a design direction, not completed eKYC. AWS remains undecided; an AWS native bridge, advanced liveness, OCR/NFC and commercial KYC are not automatic dependencies. Reference acceptance alone is not BR-03 completion, and ordinary face comparison does not establish live presence. No lecturer-approved exception or reduced feature coverage is implied.

## Evidence and interpretation

- [FinalProject_2026_2027.pdf](FinalProject_2026_2027.pdf), all three pages, was reread through text extraction and visual inspection. It defines the assignment outcomes.
- [Marking.xlsx](Marking.xlsx), worksheet `Marking`, rows 4-18, was checked for feature coverage, design/report criteria, and weights. It adds report-format expectations.
- User-confirmed inputs: Flutter/Dart, NestJS/TypeScript, and Supabase selected under free technology-stack choice; Android/iOS flexibility and easier upgrades; deadline shown as 1 December 2026 at 12:00 AM; a Google console account with identity verification pending, understood to mean Play Console. Account state has not been inspected directly.
- [REQUIREMENTS.md](REQUIREMENTS.md) is the compact requirement register. This document expands its clauses and interpretations. [DESIGN.md](DESIGN.md) distinguishes confirmed implementation choices from detailed proposals; neither creates additional assignment requirements.

If this interpretation conflicts with the original brief/rubric, correct the interpretation. Do not silently change the source or omit a requirement. The PDF's requested capabilities remain baseline scope even where it uses the word "should".

| Classification | Meaning | Examples |
| --- | --- | --- |
| Assignment requirement | Outcome the delivered project must demonstrate. | Android, two roles, eKYC, transaction 2FA, account types, walking routes, activity-linked chatbot. |
| Assignment preference | Stated preference with alternatives still allowed. | Cloud database preferred. |
| Assignment example | Named mechanism/provider illustrating an outcome. | Face-photo flow, OTP, Firebase, VNPay, Stripe. |
| Permitted option | Explicitly allowed by the brief. | On-device SQLite; choosing the bank/app name. |
| Open interpretation | Wording does not determine an implementation detail or exact breadth. | Purchase/booking categories; eKYC depth; real versus sandbox integrations. |
| User goal/input | Additional direction supplied by the user. | Future iOS flexibility, upgradeability, deadline, free stack choice. |
| Confirmed implementation choice | A technology decision accepted by the user, separate from the assignment wording. | Flutter/Dart, one NestJS/TypeScript API, Supabase-hosted PostgreSQL, Supabase Auth, private Supabase Storage. |
| Engineering proposal | A way to implement the requirements correctly. | Atomic updates, idempotency, repositories, ledger structure. |
| Approved exception | A documented change accepted by the lecturer. | None currently established. |

## Detailed business scope

The evidence below is a proposed demonstration of the specified outcome. It must be adapted to the chosen implementation without adding unrelated product features.

### 1. User profiles and roles

Source: PDF p. 1, Business 1. Register: BR-01 and BR-02.

| Clause to preserve | Required observable behavior | Boundary |
| --- | --- | --- |
| Two types of user | Bank customers and bank officers can use the app. | A third administrator role is not requested. |
| Different interfaces and permissions | Each role receives appropriate screens/actions; an unauthorized role cannot perform the other role's privileged actions. | Two separate applications or an officer website are not requested. |
| Officers create accounts for customers | An officer can provision a customer account. | The wording does not distinguish login identity from banking account. A proposed flow should cover customer identity plus an initial banking account; document that decision. |
| Officers modify customer data upon request | Demonstrate an officer making a requested customer change. | The request condition matters. An in-app support-ticket/approval subsystem is not prescribed. |
| Customers view and modify their banking information | Customers can view their own information and meaningfully edit permitted fields. | Define editable fields. This wording does not authorize users to set balances, grant roles, or override officer-managed rates. |

Customer self-registration is not explicitly required. Decide how a downloaded app gives users a usable onboarding/demo path while preserving the officer-provisioning requirement.

### 2. Login, identity, and transaction security

Source: PDF p. 2, Business 2. Register: BR-03 and BR-04.

| Clause to preserve | Required outcome or source example | Evidence and boundary |
| --- | --- | --- |
| Login screen | Users can log into the system through a login screen. | Demonstrate login and role-appropriate access. A static role selector alone is insufficient evidence. |
| eKYC | The system identifies customers/users electronically. | Show the actual enrollment/verification flow and its result. The exact verification method is not specified. |
| Officer assistance with biometrics | The paragraph describes officers helping customers provide biometric identification. | Preserve an officer-assisted path in the baseline design. How officers themselves are identified is an open actor interpretation. |
| Face scanning and picture upload | This is explicitly an example of biometric enrollment. | No particular camera library, face-matching algorithm, liveness service, OCR system, or commercial eKYC vendor is prescribed. |
| High-value verification | The face-photo example says that the image is used to verify high-value banking activity. | Preserve the high-value verification intent. Choose the method and threshold explicitly; do not treat an uploaded picture as proof of a later identity check. |
| All transactions pass 2FA before persistence | Two-factor verification applies to financial transactions before they are persisted. | Do not restrict it to login or transfers, or invent a low-value exemption. |
| OTP | An example of the second-factor mechanism. | If chosen, test invalid, expired, reused, and mismatched codes. The PDF does not require SMS rather than another suitable factor/channel. |

The implementation must define which actions create financial transactions. The conservative baseline includes transfers, deposits, withdrawals, bill payments, phone top-ups, and purchase/booking payments. Avoid introducing automatic financial postings that create extra 2FA policy questions when the brief only requests a display or calculation.

Persistent intent/challenge records, failed-attempt metadata, and posted financial transactions are different concepts. The PDF does not spell out their storage lifecycle. Document the interpretation and ensure unverified actions never become completed financial transactions or change balances.

### 3. Account management

Source: PDF p. 2, Business 3. Register: BR-05 to BR-08.

| Clause to preserve | Demonstration | Scope boundary |
| --- | --- | --- |
| Customers view their own accounts | Account list/detail tied to the current customer. | Do not make another customer's accounts visible as a shortcut. |
| Checking, saving, and mortgage accounts | All three types exist with different information views. | Three identical cards with different labels do not demonstrate the specified information differences. |
| Checking and saving balances | Show the balance for each of those account types. | A combined total alone does not cover per-account balance information. |
| Saving rates and monthly profits | Show both the rate and monetary profit per month. | A rate alone is insufficient; automated interest payout is not explicitly required. |
| Officers change saving rates according to bank policies | Officer can change applicable rates and the displayed calculation reflects the documented policy. | Define the policy/effective-date behavior; a full policy engine or multilevel approval system is not prescribed. |
| Mortgage amount due monthly or every two weeks | Show an actual amount due for the chosen repayment convention. | Both frequencies are not explicitly required. A mortgage balance alone is insufficient. |
| Account transaction history | Show the account's transactions and meaningful results/details. | Cross-account visibility must respect ownership/permissions. |
| Deposits and withdrawals | Demonstrate both adding and withdrawing money. | The source uses "or" to describe user actions; retain both as the baseline. Their applicability to each account type needs a stated rule. |

The brief does not specify rates, interest formula, rounding, term lengths, repayment formula, fees, minimum balances, or which account types permit each operation. The team should document a small, consistent set of demo banking policies. These missing parameters do not imply a requirement to build loan applications, underwriting, credit scoring, collateral management, debt collection, or automatic mortgage repayment.

### 4. Transaction management and payment integration

Source: PDF p. 2, Business 4, linked to Business 2. Register: BR-09 and BR-10.

| Clause to preserve | Demonstration | Scope boundary |
| --- | --- | --- |
| Follow the security requirements | Transactions use the selected identity/2FA mechanisms. | Payment, utility, and transfer screens must not bypass them. |
| Verify the operation is allowed and valid before persistence | Check permissions/policy and data/business validity before committing the result. | Exact rules are implementation decisions; hiding a UI button is not sufficient authorization. |
| Transfer to other accounts in the same bank | Complete an internal transfer with consistent source/destination results and history. | Show actual persistent behavior, not only a success message. |
| Transfer to accounts in other banks | Demonstrate the external-bank transfer path and outcome. | The source lists same-bank "or" other-bank destinations; retain both as conservative coverage. Do not use this wording to silently omit interbank transfers. |
| Payment-service integration | Show an actual integration with a selected payment service. | VNPay and Stripe are examples; both are not required. A hardcoded provider screen is not integration evidence. |

A payment checkout does not automatically satisfy the separate interbank-transfer capability. The PDF does not specify live money, sandbox credentials, provider callbacks, real banking-network access, or acceptance of a simulated external bank. Keep these distinct in the implementation and demo. Obtain course clarification where a sandbox or simulation will stand in for a requested external behavior; do not report unresolved simulated behavior as complete.

Use only the transaction handling needed for correctness of the selected flows. Atomic local updates and duplicate-request protection are sensible engineering support. A general accounting platform or comprehensive settlement/reconciliation product is not a separate assignment deliverable.

### 5. Utilities

Source: PDF p. 2, Business 5. Register: BR-11 and BR-12.

| Capability | Source interpretation | Demonstration |
| --- | --- | --- |
| Electricity bills | Explicit requirement. | Identify the bill/account, confirm the amount, authorize payment, and show its result. |
| Water bills | Explicit requirement, separate from electricity. | Show a water-bill flow, not just a generic unused menu entry. |
| Phone-account top-up | Explicit requirement. | Choose the phone account/amount and show the authorized result. |
| Flight tickets, movie tickets, hotel rooms, or e-commerce products | The final bullet uses an "or" list. Exact required breadth is unresolved. | Keep all named alternatives visible in planning until the expected category coverage is settled. |

Do not silently assume one purchase category has been accepted, or automatically commit to building all four full booking systems. A chosen category needs its requested purchase/booking/payment behavior; it does not imply building an airline reservation system, hotel inventory platform, cinema administration system, or full e-commerce marketplace.

Reusable confirmation/payment/result components can serve these flows. Reuse does not remove the distinct electricity, water, and phone capabilities. External fulfillment and payment completion must be described separately.

### 6. Location and navigation

Source: PDF p. 2, Business 6. Register: BR-13.

Required clauses are: locate the user; show the user on a map; show all nearby bank offices; recommend the shortest walking path to the nearest office.

Define the branch dataset/coverage area, nearby radius, and meaning of nearest. These are unspecified parameters, not reasons to claim worldwide branch coverage. Within the declared supported area, include every qualifying nearby branch from the maintained dataset.

The result must be a walking-route recommendation. Map pins alone, a straight line, a distance label, a list of addresses, or driving directions alone do not demonstrate this requirement. Distinguish the nearest-office selection metric from the shortest walking route to that office. A route provider/algorithm can supply the recommendation; the word "intelligent" does not itself mandate training an AI model.

Denied location permission and unavailable routes need understandable behavior as implementation quality checks. They are not additional product features.

### 7. Intelligent chatbot

Source: PDF p. 2, Business 7. Register: BR-14.

The app must have a chat screen where users ask questions and receive intelligent answers with links to requested activities. Explicit examples include phone services, monthly bills, and transactions of the month.

Demonstrate actionable destinations: a phone-services request opens the corresponding flow, a bill request reaches the appropriate service, and a month-specific history request preserves the requested month/filter. A generic greeting, static FAQ, or unlinked answer alone does not cover the requested behavior.

No particular LLM, generative model, AI vendor, custom model training, or autonomous agent is specified. Choose a mechanism that demonstrates the required conversational behavior. Links can open normal app screens; they do not imply permission for the chatbot to execute transfers or bypass transaction authorization. Persistent chat history, voice chat, investment advice, and credit decisions are not prescribed.

## Technical and submission deliverables

| Register ID | Required deliverable | Source and scope |
| --- | --- | --- |
| TR-01 | Team of 2-3 members | PDF p. 3, Technical 1. Actual team membership is still unknown. |
| TR-02 | Android app implementing every business group | PDF p. 3, Technical 1. iOS is an additional user compatibility goal, not a stated deadline deliverable. |
| TR-03 | Persistent application data in a database | PDF p. 3, Technical 2. SQLite on-device is allowed; cloud database is preferred; Firebase is an example. Explain any file/object-storage plus database-reference design as an implementation choice. |
| TR-04 | Google Play deployment, downloadable/installable/usable on users' smartphones | PDF p. 3, Technical 3. A locally installed APK or internal test alone is not the same outcome without an agreed exception. Provide a coherent customer provisioning/demo path. |
| TR-05 | Analysis/design report with applied principles, patterns, practices, class diagrams, ER/database diagrams, use cases, and component/infrastructure solution diagrams as applicable | PDF p. 3, Technical 4. Required class/ER/use-case evidence must not be dropped by interpreting "if any" as applying to every diagram. Draw the actual architecture; no extra infrastructure is demanded. |
| TR-06 | Implementation/code structure/technology explanation and all UI functionality | PDF p. 3, Technical 4. Match the report to the delivered application. |
| TR-07 | Demo video showing the app's features | PDF p. 3, Technical 5. Cover both roles and all required groups. No video length is specified. |
| TR-08 | Faculty report format, index/table of contents, correct spelling, coherent presentation, references | Workbook `Marking`, row 17. These rubric details are additional to the PDF's report-content list. The faculty template is not yet supplied. |

The deadline is user evidence from the submission portal, not a date in the PDF: 1 December 2026 at 12:00 AM, the start of that day. The internal 29 November target is a proposal. The screenshot does not identify its timezone.

The rubric awards architecture/rationale 1 point, class diagrams 1, UI 1, database design 1, features collectively 5, and report/demo presentation 1. All seven feature groups remain required regardless of their individual weights. Its top feature descriptors expect stable and complete functionality; no particular technology earns a named bonus. Source cell references and the two self-assessment formula issues are recorded in [REQUIREMENTS.md](REQUIREMENTS.md).

## Decisions the source cannot settle

These are decision records to resolve as needed, not a blanket requirement to stop all work.

| Decision | Current treatment | Who/what resolves it |
| --- | --- | --- |
| Core stack and remaining infrastructure | Flutter/Dart, one NestJS/TypeScript API, Supabase-hosted PostgreSQL, Supabase Auth, and private Supabase Storage confirmed on 2026-10-13. The base uses ChangeNotifier, `pg`, SQL migrations, and local Supabase. Android and persistence remain assignment requirements; cloud is preferred. | API hosting and external provider configuration remain team choices within time/budget constraints. No stack reselection is needed. |
| Account provisioning and editable fields | Preserve officer creation and customer editing; distinguish identity from banking accounts. | Team documents a coherent flow and field permissions. Clarify only if course expectations conflict. |
| eKYC actors and depth | Retain eKYC, officer assistance, and high-value verification intent. | Choose a demonstrable method; clarify any expected biometric depth, simulated verification, or officer-enrollment interpretation with the lecturer. |
| High-value threshold and banking calculations | Unspecified. | Team defines explicit demo policies unless the lecturer supplies them. Do not invent them as assignment facts. |
| Second factor and operation lifecycle | 2FA mandatory; OTP proposed. | Team chooses a valid mechanism and documents authorization/persistence behavior. |
| External service realism | Sandbox and simulation acceptance not stated. | Lecturer clarification plus actual provider access. Track interbank, payment, biller, and purchase/booking integration separately. |
| Purchase/booking breadth | Full "or" list retained; no single-category waiver assumed. | Lecturer interpretation of Business 5's final bullet. |
| Branch scope and nearest metric | Unspecified. | Team defines a supported area/dataset and routing policy that demonstrates the wording. |
| Store usability and account provisioning | Public download required; self-signup not prescribed. | Team defines a usable onboarding/demo path; lecturer resolves any publication exception. |
| iOS release timing | Compatibility requested; deadline release not established. | User decision. Preserve architecture/plugin compatibility without adding an App Store deliverable automatically. |
| Team and faculty report template | Team size range known; members/template unavailable. | User/course materials. |

## Work not included automatically

Do not let any of these displace required outcomes:

- An iOS App Store release, web banking site, separate officer dashboard, or third admin product.
- A full airline/hotel/cinema/e-commerce platform behind the selected utility integration.
- Loan origination, underwriting, credit scoring, collateral management, debt collection, or investment/trading functions.
- Cards, ATM hardware integration, QR payments, budgeting, spending analytics, multi-currency exchange, recurring payments, or a notification center.
- Customer self-signup, support tickets, multilevel approvals, multilingual UI, dark mode, or voice chat unless separately selected for a clear reason.
- Custom authentication/eKYC platforms, custom-trained AI, or automatic chatbot money movement.
- Microservices, Kubernetes, a general ledger/accounting product, full settlement/reconciliation operations, or elaborate provider abstraction frameworks.

Small internal mechanisms may still be appropriate for correctness. For example, transaction records and a simple balanced-entry representation can support transfers without building a general accounting product. Audit metadata can support an officer edit without a new audit dashboard. Rate configuration can support savings calculations without a policy engine. Record the connection to a requirement and keep the mechanism proportionate.

## Evidence and scope control during implementation

1. Link each feature task to a BR/TR ID above or identify the minimal technical support it needs.
2. Keep source requirements, implementation decisions, and additional features distinct. An architecture choice does not create another grading requirement.
3. For each required outcome, record the working screen/flow, relevant persistence/permissions, and a demo/report reference. Do not mark it complete from a menu, mockup, or success toast alone.
4. Label live, provider-sandbox, simulated, and unavailable behavior accurately. A demo fixture is not evidence of an external integration.
5. Use focused checks for the behaviors being implemented, especially transaction validity, role restrictions, and chosen 2FA. No arbitrary coverage target or enterprise test process is prescribed by the brief.
6. Update class/database/use-case/component diagrams when the implementation changes. Build report evidence alongside the app.
7. If time becomes constrained, reduce implementation complexity and unrequested extras first. Preserve the seven business groups, required design evidence, Play deliverable, and demo video; document any actual lecturer-approved exception separately.

Review coverage: PDF p. 1 Business 1; p. 2 Business 2-7; p. 3 Technical 1-5; workbook architecture/design rows 4-8, feature rows 10-16, report row 17, total row 18. Both source files remain unchanged.
