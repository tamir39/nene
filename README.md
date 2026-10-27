# Nene

An Android mobile banking final project for Ton Duc Thang University's Mobile Apps Development course.

Status: private reference-photo enrollment and officer review added on 2026-10-27 to the first customer/account flow. The app supports sign-in, local officer customer creation, a zero-balance checking account, contact/requested edits, reference status and acceptance/correction. Reference acceptance is not completed eKYC; full assignment coverage remains in progress.

## Confirmed technology stack

| Layer | Selected technology | Responsibility |
| --- | --- | --- |
| Mobile app | Flutter / Dart | One app with customer and officer interfaces; Android delivery and future iOS compatibility. |
| Backend | NestJS / TypeScript | One API for banking data, permissions, transaction verification, calculations, and external integrations. |
| Database | PostgreSQL hosted on Supabase | Persistent application records and atomic financial updates. |
| Authentication | Supabase Auth | Login and sessions; eKYC and transaction-specific 2FA require separate implementation. |
| Identity files | Private Supabase Storage | Controlled access to identity evidence, with references and verification state in PostgreSQL. |

Banking reads and writes go through NestJS. Flutter uses Supabase Auth for sessions; identity-file access follows backend authorization. The stack is a user decision, not a technology mandate in the assignment. [DESIGN.md](DESIGN.md) records the rationale, boundaries, trade-offs, and remaining implementation choices.

The submission portal shows **1 December 2026 at 12:00 AM**, the start of Tuesday. Plan to submit by **29 November**, with 30 November reserved as a buffer. The screenshot does not state its timezone; see [REQUIREMENTS.md](REQUIREMENTS.md) for the planning assumption.

## Start here

- [ROADMAP.md](ROADMAP.md): the ordered checklist of remaining work and the immediate next feature flow.
- [docs/SETUP.md](docs/SETUP.md): prerequisites, local setup, run commands, and verification.
- [docs/API.md](docs/API.md): the implemented profile, customer, initial-account and private-reference contract.
- [docs/REFERENCE_FLOW.md](docs/REFERENCE_FLOW.md): reference capture/review, notice/retention defaults and web-demo steps.
- [docs/CUSTOMER_FLOW.md](docs/CUSTOMER_FLOW.md): first-demo decisions, provisioning/retry flow and implemented data relationships.
- [SCOPE.md](SCOPE.md): detailed PDF/rubric audit, required outcomes, examples, open interpretations, and boundaries against scope expansion.
- [REQUIREMENTS.md](REQUIREMENTS.md): all assignment requirements, the 10-point rubric, source issues, and open decisions.
- [DESIGN.md](DESIGN.md): confirmed stack, proposed architecture, roles/screens, transaction flow, conceptual data model, and implementation order.
- [docs/BRANDING.md](docs/BRANDING.md): selected Open pocket logo direction, palette, reference artwork, and remaining asset work.
- [docs/SCREEN_MAP.md](docs/SCREEN_MAP.md): proposed customer/officer destinations, PDF traceability, shared financial flows, and recovery states.
- [docs/UI_DIRECTION.md](docs/UI_DIRECTION.md): sign-in, customer home, and officer workspace previews with a local interactive design study.
- [AGENTS.md](AGENTS.md): instructions for working in this repository.

## Assignment sources

- [FinalProject_2026_2027.pdf](FinalProject_2026_2027.pdf): project brief.
- [Marking.xlsx](Marking.xlsx): marking criteria, worksheet `Marking`.

The required feature groups are user profiles, security/eKYC/2FA, account management, transaction management, utilities, navigation, and an intelligent chatbot. Submission also includes design/implementation/UI reporting, a demo video, and Google Play deployment.

The brief requires Android, permits on-device SQLite, and prefers a cloud database with Firebase as an example. It does not prescribe a language, backend framework, serverless hosting, or an iOS submission. See the source audit in [REQUIREMENTS.md](REQUIREMENTS.md) before treating any proposed technology as mandatory.

## Current foundation

- `app/`: Flutter sign-in and distinct customer/officer workspaces. Customer profiles/accounts and permitted edits come through the API. Android is the delivery target; iOS platform files preserve a future starting point. A local Microsoft Edge preview runs the same app for development.
- `backend/`: one NestJS API with server-verified sessions, scoped customer/account reads and writes, local Auth provisioning and safe creation retries.
- `infrastructure/`: local Supabase configuration, restricted database privileges, profile/account/request/audit migrations, private identity bucket and access tests.
- `scripts/`: local configuration, an explicit local migration fallback, and API/Auth/database checks that remove their synthetic fixtures afterward.

This demonstrates a local BR-01/BR-02 customer flow and partial BR-03/BR-05/TR-03 support. There are no money movements, saving/mortgage flows, eKYC checks, transaction 2FA, external integrations, maps or chatbot yet. Customer creation uses local-only synthetic activation; hosted onboarding remains open. No cloud resources or store release have been provisioned. The private identity bucket now supports backend-authorized reference upload/preview and officer review. AWS and the later comparison provider remain undecided.

Start Docker, then use the commands in [the setup guide](docs/SETUP.md). Local configuration and SDK files are ignored by Git. Never put database or Supabase administrative credentials in the app.

For a browser preview on this Windows PC, use `npm run setup:browser` and the [Microsoft Edge run instructions](docs/SETUP.md#preview-the-app-in-microsoft-edge). This loopback preview uses the existing local backend and database; it adds no hosted web release or separate banking application. Browser refresh drops the memory-only session.

The lighter Open pocket identity is approved and applied to Flutter sign-in/profile/loading/error screens and the Android launcher. The [screen map](docs/SCREEN_MAP.md) and [three-screen UI study](docs/UI_DIRECTION.md) describe the wider planned app; their sample balances and financial controls are not implemented. Final wordmark/release asset review and iOS launcher artwork remain open; see [the branding decision](docs/BRANDING.md). Team responsibilities, backend hosting, integration expectations/providers, and account rules remain open. The foundation does not add an iOS release, a separate officer application, or extra business features to the PDF scope.
