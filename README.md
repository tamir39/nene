# Nene

An Android mobile banking final project for Ton Duc Thang University's Mobile Apps Development course.

Status: local project foundation created on 2026-10-15 using the stack confirmed on 2026-10-13. The app supports sign-in and a server-authorized profile; the complete assignment features remain in progress.

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
- [docs/API.md](docs/API.md): the implemented health and authenticated-profile contract.
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

- `app/`: Flutter sign-in, session state, authenticated profile, and sign-out. Customer/officer roles come from the backend. Android is the delivery target; iOS platform files preserve a future starting point.
- `backend/`: one NestJS API, server-verified Supabase sessions, and read-only profile access through the PostgreSQL `pg` driver.
- `infrastructure/`: local Supabase configuration, a restricted database role, profile migration, private identity bucket, and database access tests.
- `scripts/`: local configuration and an API/Auth/database integration check using a temporary synthetic identity that is removed afterward.

This is partial support for BR-01/BR-03 and TR-03, not completion of any business feature group. There are no financial operations, eKYC checks, transaction 2FA, officer provisioning, profile editing, external integrations, maps, or chatbot yet. No cloud resources or store release have been provisioned. The identity bucket has no app upload flow yet.

Start Docker, then use the commands in [the setup guide](docs/SETUP.md). Local configuration and SDK files are ignored by Git. Never put database or Supabase administrative credentials in the app.

Open pocket in teal + apricot is the selected logo direction. A [screen map](docs/SCREEN_MAP.md) and [three-screen UI study](docs/UI_DIRECTION.md) are proposed for review; they are not implemented app features. Production artwork, final typography/styling approval, and app integration remain to do; see [the branding decision](docs/BRANDING.md). Team responsibilities, backend hosting, integration expectations/providers, and account rules remain open. The foundation does not add an iOS release, a separate officer application, or extra business features to the PDF scope.
