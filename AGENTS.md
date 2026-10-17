# Nene workspace instructions

## Project context

This repository is starting a Ton Duc Thang University Mobile Apps Development final project: an Android mobile banking application. `Nene` is the current repository name; the bank name and public app name remain open.

The stack was confirmed on 2026-10-13 and local scaffolding authorized on 2026-10-15: Flutter/Dart, one NestJS/TypeScript backend API, and Supabase for PostgreSQL, Auth, and private Storage. The base supports sign-in, server-controlled profiles, and local persistence/access checks. No financial operations, eKYC, transaction 2FA, or external integrations exist yet. Do not describe planned features as implemented.

## Read first

- [README.md](README.md): repository status and documentation map.
- [SCOPE.md](SCOPE.md): detailed source audit, required outcomes, unresolved interpretations, and scope boundaries.
- [REQUIREMENTS.md](REQUIREMENTS.md): assignment requirements, rubric, and open questions.
- [DESIGN.md](DESIGN.md): confirmed stack, proposed architecture, data model, screen flows, and delivery order.
- [docs/SETUP.md](docs/SETUP.md) and [docs/API.md](docs/API.md): local commands, verification limits, and the implemented API contract.
- `FinalProject_2026_2027.pdf`: authoritative assignment brief.
- `Marking.xlsx`, worksheet `Marking`: authoritative assessment rubric.

Keep original assessment files intact unless the user explicitly requests changes. If an interpretation or proposal conflicts with either source, flag it and clarify rather than silently dropping a requirement.

## Shared workspace guidance

The user supplied global Twohearts workspace notes. They identify `D:\Data\Downloads\Policies` as the policy bundle to consult for collaboration, branching/releases, testing gates, issue/spec/PR review, product intake, engineering standards, and QA.

The supplied path was checked on 2026-10-12, 2026-10-13, 2026-10-15, and 2026-10-17 and was unavailable. No policy contents were read. When those areas are touched, check for the bundle again and apply relevant available instructions. If it remains unavailable, state the limitation and proceed with work that does not depend on knowing its contents. Do not invent policy gates or claim policy compliance.

The notes identify `D:\Projects\TwoheartsMissonControl`, `D:\Projects\TwoheartsDeliveryDashboard`, and `D:\Projects\Whitelable` as a related product/workflow family. Nene's membership in that family has not been established; do not import their product requirements or modify those repositories as part of this assignment.

## Working rules

- Distinguish assignment requirements, proposed choices, confirmed decisions, and lecturer-approved exceptions in documentation.
- The user selected Flutter/Dart + NestJS/TypeScript + Supabase on 2026-10-13. Use Supabase-hosted PostgreSQL, Supabase Auth, and private Supabase Storage. Follow this confirmed choice; do not reopen framework selection or add Firebase/another backend without a concrete need and a user decision.
- Keep one mobile app, one backend application, and one application database. Route banking reads and writes through NestJS. Use Supabase Auth for sessions and backend-authorized access to private identity files. Keep domain logic in the backend and provider access out of screen widgets; do not add microservices or a parallel Edge Functions backend by default.
- The foundation uses Flutter's built-in ChangeNotifier and repositories, the PostgreSQL `pg` driver with parameterized SQL, and locked dependencies. Backend hosting and external providers remain open. Local scaffolding is authorized; cloud provisioning, paid services, and publication are not side effects of that authorization.
- Keep the base's memory-only mobile sessions until secure persistence is deliberately implemented and checked. Public signup is disabled; do not add self-registration or a client role selector. The current `nene_api` database role is read-only; add narrowly scoped privileges only alongside authorized backend features.
- Treat Android, database persistence, eKYC, transaction 2FA, and Google Play delivery as assignment requirements. Cloud database hosting is preferred; Firebase, face-photo verification, OTP, VNPay, and Stripe are examples or proposed mechanisms. Do not turn them into mandatory product choices. See the technology-constraint audit in `REQUIREMENTS.md`.
- The submission portal shows 1 December 2026 at 12:00 AM, meaning the start of that day. Plan to submit before the end of 30 November; the proposed internal target is 29 November. The screenshot does not state its timezone. See `REQUIREMENTS.md` for the evidence and planning assumption.
- Preserve all seven business feature groups. Delivery phases are an implementation order, not permission to omit later requirements.
- Keep work tied to a BR/TR requirement or the minimal engineering support needed to implement it correctly. Use `SCOPE.md` to avoid expanding into extra apps, a full banking/booking platform, or an unrequested iOS release. Future iOS flexibility is a user goal; its release deadline is not established.
- Use requirement IDs from `REQUIREMENTS.md` in implementation plans and acceptance evidence. Explain each architecture and technology choice so it can support the project report.
- Keep changes focused and keep documentation aligned when behavior or decisions change. Prefer a simple structure suitable for a team of 2-3 people.
- Do not create accounts, incur provider costs, publish to Google Play, or use real customer data as a side effect of local implementation.
- Record mocks and sandbox integrations explicitly. A simulated service must not be presented as a live banking integration or as satisfying an unresolved lecturer expectation.

## Git workflow

The user requested commits and pull requests for completed work on 2026-10-17.

- Use a focused `codex/` branch for each coherent change. Keep direct implementation commits off `main`.
- Commit meaningful increments, push the branch, and open a PR for the completed change. A PR may contain several related commits; individual files or small steps do not each need a PR.
- Keep dependent changes in separate PRs when that improves review. State the dependency and review order; retarget the later PR to `main` after its dependency is merged.
- Before publishing, inspect the staged diff and excluded local files, and report relevant verification and remaining limitations in the PR. Reuse valid checks for unchanged code.
- Do not merge a PR unless the user asks. Attach created PRs to the chat and include their links in the completion report.

## Banking implementation principles

These engineering constraints are separate from the assignment wording. The base enforces the session/profile boundary; financial constraints apply as those features are implemented:

- Enforce customer/officer permissions and account ownership on the backend, not only through hidden screens.
- Make the backend authoritative for financial writes. The mobile client must not directly set balances, grant roles, approve its own identity checks, or set interest rates.
- Verify Supabase sessions in NestJS and load customer/officer permissions from server-controlled data. Keep banking tables inaccessible through client-facing Supabase data APIs so they cannot bypass the backend. Supabase Auth does not itself implement eKYC or transaction-bound 2FA.
- Enforce transaction-bound 2FA for financial operations. If OTP is selected, use it with the authenticated session and bind it to the operation. Device unlocking or local biometrics alone do not establish eKYC or replace transaction 2FA.
- Validate money movements, commit related balances and transaction records atomically, and prevent duplicate posting when requests or provider callbacks repeat. A detailed double-entry ledger/clearing system is an optional design mechanism, not an additional assignment feature.
- Represent money using integer minor units with an explicit currency. Keep calculation and rounding rules documented and independently testable.
- Use synthetic demo identities and private storage for identity evidence. Keep provider secrets, OTP values, identity images, and sensitive financial data out of source control and logs.
- Keep Supabase administrative/service credentials and PostgreSQL credentials on the backend. Use minimal database privileges and private storage access; privileged credentials never belong in the Flutter app.
- The chatbot may explain and open allowlisted app destinations. It must not independently authorize payments or bypass the ordinary confirmation and chosen 2FA flow.

## Verification and reporting

Use [docs/SETUP.md](docs/SETUP.md) for exact commands and verification status. Backend checks are `npm --prefix backend run check` and `npm --prefix backend run format:check`; local database checks are `npm run db:test`, and the real local Auth/API/database check is `npm run check:local`. Flutter checks run inside `app/` with `flutter analyze` and `flutter test`. Keep commands aligned with the installed tooling and report platform checks that cannot run on this host.

As features are added, prioritize meaningful checks for authorization, account ownership, the chosen 2FA mechanism (including OTP expiry/reuse if selected), insufficient funds, concurrent transfers, idempotency, payment callbacks, savings/mortgage calculations, and critical customer/officer flows. Test provider failures and denied camera/location permissions where relevant.

Documentation-only changes need source, link, consistency, and diff review; they do not need an invented application test suite. Report what was checked and what remains unverified.

Maintain report evidence alongside implementation: architecture rationale, class relationships, database relationships, use cases, component/infrastructure diagrams, UI captures, and demo scenarios. Do not mark a requirement complete without demonstrable behavior and relevant verification.
