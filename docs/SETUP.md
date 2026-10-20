# Local development

The project uses one Flutter app, one NestJS API, and a local Supabase stack. The first flow supports officer customer creation, initial checking accounts and permitted customer/officer profile edits alongside sign-in. It does not implement money movements, saving/mortgage flows, eKYC, transaction 2FA or external integrations.

## Prerequisites

- Node.js 24 and npm 11. This setup was checked with Node 24.14.1 and npm 11.11.0.
- Docker Desktop running Linux containers. Docker Engine 29.5.3 was used for local checks.
- Flutter stable with its bundled Dart SDK, Android Studio, Android SDK, and a compatible JDK. This setup uses Flutter 3.47.7 (revision `abaf9c5237`) and Dart 3.13.5. The local SDK is in the ignored `.tools/flutter/` directory; it is not included in the repository. Flutter verification details are recorded below.
- Git. On another workstation, install the SDK through the [official Flutter setup](https://docs.flutter.dev/install).

The repository pins Supabase CLI 2.121.0, NestJS 12.1.3, TypeScript 6.0.3, and `pg` 8.23.1. Lockfiles record the complete dependency versions. The Nest application uses TypeScript compilation directly; a global Nest CLI is unnecessary.

The generated Android project uses Gradle 9.3.1 with a pinned distribution checksum. Flutter requests Android SDK Platform 36 and NDK 28.2.13676358; these can be installed through Android Studio's SDK Manager. The first build may download missing SDK components when their licenses are already accepted.

## Start the local services

Run these commands from the repository root in PowerShell. Start Docker Desktop first. Initial dependency and container downloads require network access.

```powershell
npm ci
npm --prefix backend ci
npm run db:start
npm run setup:local
npm run api:dev
```

`db:start` applies migrations on a fresh local database. After adding migrations to an existing database, use `npm run db:migrate`. This workstation's Supabase CLI reports a local PostgreSQL connection timeout; `npm run db:migrate:docker` is an explicit local-only fallback. It verifies the named Nene container and applies each pending migration plus its CLI history entry in one transaction. It does not reset data. Avoid database reset commands: they delete local development data.

`setup:local` uses only the named Nene local stack. It creates a random password for the restricted `nene_api` database login, then writes ignored files:

- `infrastructure/.env.api.local`: restricted local PostgreSQL credential.
- `backend/.env`: local API/Auth/database configuration, including the backend-only `SUPABASE_SECRET_KEY` for local demo provisioning.
- `app/config/local.json`: public client key and Android-emulator URLs.

It refuses to overwrite existing backend/app configuration. Reuse those files on subsequent starts; update them deliberately if necessary. No cloud project, payment service, or provider account is created.

For an existing foundation configuration, run `npm run setup:local:provisioning` after starting Supabase. This explicitly writes/refreshes only `SUPABASE_SECRET_KEY` in the ignored local backend configuration; it refuses a nonlocal/production target and never adds the secret to Flutter. Without this key, login/read behavior remains available and customer creation returns 503. Creation is deliberately disabled against hosted Auth or in production until hosted activation is designed.

The API defaults to `127.0.0.1:3000`, Supabase to `127.0.0.1:54321`, and local Studio to `127.0.0.1:54323`. This workstation's manual demo uses API port **3001** because another application uses 3000: set `$env:PORT='3001'` before starting the API and use `http://10.0.2.2:3001/api/v1` as `API_BASE_URL` in the ignored app configuration. The API prefix is `/api/v1`. `GET /api/v1/health` checks process liveness only. See [API.md](API.md) for authentication and profile behavior.

Local Supabase includes development administration tools. Keep it on a trusted development machine. `npm run db:status` displays local credentials, so do not paste its output into reports, screenshots, or chat. `npm run db:stop` stops the local stack while retaining its data. Stop the API with Ctrl+C.

## Run the Android app

With the local Flutter SDK, run from `app/`:

```powershell
..\.tools\flutter\bin\flutter.bat --no-version-check pub get
..\.tools\flutter\bin\flutter.bat --no-version-check run --dart-define-from-file=config/local.json
```

Launch an Android emulator first, or select it when Flutter asks. If Flutter is on PATH, use `flutter` in place of the local SDK path. The generated configuration uses `10.0.2.2` to reach the Windows host from the Android emulator. Do not copy these URLs into a hosted build.

`--no-version-check` skips an optional SDK update check that stalled during this workstation's first setup. Upgrade the SDK deliberately and rerun the project checks afterward.

This workstation's initial setup used the ignored `.cache/pub/` package cache. To reuse it, set `$env:PUB_CACHE = Join-Path (Resolve-Path '..').Path '.cache\pub'` while in `app/` before running Flutter. Other workstations may use Flutter's normal cache. The committed `pubspec.lock` keeps application dependency versions consistent either way.

The app's configuration validator accepts HTTP only for explicitly allowed local hosts in debug mode; release/profile configuration requires HTTPS. Android's native network policy also rejects release cleartext traffic, while Dart HTTP relies on the app's configuration guard. A physical device needs suitable secure service URLs or an explicit development networking setup; it cannot use the emulator's `10.0.2.2` alias. iOS simulator/device builds require macOS and Xcode and have not been validated on this Windows host.

There is no public signup or automatic persistent demo user in the tracked setup. Bootstrap an initial synthetic **officer** through local Studio's Auth administration, then insert its Auth UUID, synthetic display name and `officer` role into `bank.user_profiles` using the local SQL editor. That trusted setup is separate from the app: sign in as the officer and use **Create customer** to exercise actual customer/account provisioning. Existing foundation demo customers may have no account and correctly show an empty state. Do not use real personal data or commit development credentials.

Sessions currently remain in memory; restarting the app requires signing in again. Secure persistent sessions can be added deliberately later. The app does not store refresh tokens in plaintext preferences.

## Checks

From the repository root:

```powershell
npm --prefix backend run check
npm --prefix backend run format:check
npm run db:test
npm run check:local
npm run check:customer-flow
```

- Backend checks: lint, TypeScript build, and 48 tests for session/role boundaries, provisioning reconciliation, field validation, scoped queries, failures and connection/TLS settings.
- Database checks: 56 pgTAP assertions for column grants, RLS, profile/account constraints, request identity immutability, edit audit protection and private storage access. The runner executes inside the named local Docker container and rolls back its synthetic fixtures. It avoids a Windows connection failure observed with the CLI's `test db` command.
- Integration check: starts its own temporary API process, signs into local Supabase, and verifies real PostgreSQL-backed customer/officer profiles, metadata isolation, missing/disabled profiles, and invalid-session rejection. Connections are pinned to local services; its temporary identity/profile are removed afterward. Docker and local Supabase must already be running.
- Customer-flow integration: creates a temporary synthetic officer, races two initial creation requests, checks replay/changed-payload/duplicate-email behavior, signs in the new customer, verifies own accounts/contact edits and denied access, makes an officer-requested edit, then restarts the API and checks persistence. It removes its test accounts, requests, audits, profiles and Auth identities afterward. It does not reset the database or modify persistent manual-demo users.

From `app/`:

```powershell
..\.tools\flutter\bin\flutter.bat --no-version-check analyze
..\.tools\flutter\bin\flutter.bat --no-version-check test
..\.tools\flutter\bin\flutter.bat --no-version-check build apk --debug --dart-define-from-file=config/local.json
```

Review fixes verified on 2026-10-17: backend lint, build, formatting, and all 23 tests passed. Flutter analysis and formatting passed, and all 24 mobile tests passed, including stalled Auth response and late-login regressions. The Android debug APK was rebuilt successfully at `app/build/app/outputs/flutter-apk/app-debug.apk` (173,197,097 bytes). APK metadata confirms the development application ID, version `0.1.0`, target SDK 36, and debug status. Emulator/device runtime was not verified in that check; see the later preview check below. iOS builds remain unverified.

The 24 database assertions and real local Auth/API/PostgreSQL integration passed on 2026-10-15, and the integration check removed its temporary identity. Public signup was separately rejected with `signup_disabled`. A fresh integration attempt on 2026-10-17 stopped during local service configuration because the Docker engine was unavailable, before creating a fixture; it is not a new passing integration result.

## Lighter Flutter preview verification (19–20 October 2026)

This historical preview check covered the approved lighter palette and scalable Open pocket mark on sign-in, loading/error states, both server-controlled profile variants, and Android launcher/startup resources. That styling change added no dependencies or authentication/backend behavior. The later customer-flow check below supersedes its feature-status notes.

- Flutter analysis passed and all **26 tests** passed. Added checks cover a 320×640 viewport at 200% text size with the keyboard open, reachable sign-in/error feedback, customer profile boundaries and sign-out. Officer display and existing session/API tests also passed.
- The debug APK built with `--no-pub --dart-define-from-file=config/local.json`, installed successfully with `adb install -r`, and launched on `emulator-5554`. The existing `Medium_Tablet` AVD uses a phone-sized 1080×2400 override at density 420. [Actual emulator sign-in capture](ui/android-signin.png) records the lighter design. Full screen-reader, physical-device and launcher-mask testing remain open.
- Docker's Nene containers are running. The existing synthetic customer login was verified directly against local Supabase Auth, NestJS on port 3001, and PostgreSQL. This was a targeted manual-demo check, not a rerun of the full integration suite or an on-device sign-in assertion. Backend/database code was unchanged; prior checks above remain the recorded evidence.
- Existing local demo credentials were retained only in ignored `.tmp/nene-demo-login.json`; no credentials, tokens or local configuration were committed. At that preview checkpoint the app was left at sign-in; officer provisioning and banking accounts had not yet been added.

For cached dependencies, the three Flutter check/build commands above accept `--no-pub`; this avoids an unnecessary package fetch. The SDK and package cache remain local and ignored.

## Customer flow verification (20 October 2026)

- Backend lint/build, all 48 tests and formatting passed.
- Flutter analysis/formatting and all 54 tests passed, including contact-save recovery, exact creation retries, confirmed duplicate-email correction, ordinary background/resume, session changes and a small phone with enlarged text/keyboard.
- All 56 database assertions passed with rollback. Both the original Auth/API check and the new real customer-flow check passed; the latter includes concurrent initial creation and persistence after restarting the API. Temporary fixtures were removed.
- The additive migration was applied through `db:migrate:docker` after the CLI connection timeout. Repeating that command applied zero migrations and retained existing data.
- The debug APK built successfully, installed on the phone-sized Android emulator, and passed a manual journey: officer sign-in → create/review/confirm customer → requested address correction with a reason → sign out → new customer sign-in → own zero-balance VND account → contact edit and saved feedback. Background/resume retained the customer workspace. Captures show the [officer workspace](ui/android-officer-workspace.png) and [customer account](ui/android-customer-account.png).
- The emulator is left signed in as the new synthetic customer. Local test access details are in ignored `.tmp/nene-demo-officer.json` and `.tmp/nene-flow-customer.json`; these are development fixtures, never application password storage or committed report evidence.

This is a local synthetic flow. Hosted activation, lost-form recovery after app process death/sign-out, email changes, secure persistent sessions, eKYC, financial 2FA, iOS and physical-device testing remain open. Ordinary background/resume keeps the current retry form; only an explicit session transition or process loss discards it.

## Scope and release boundaries

`com.example.nene_app` is the development Android application ID; the generated iOS bundle ID is `com.example.neneApp`. The Open pocket direction and lighter palette are approved and Android icons are integrated. Final wordmark/release asset review, iOS icons, identifiers, release signing, cloud hosting, and Play configuration remain open. Release signing must use a separately managed release key; no debug signing fallback is provided for publishing.

The private identity bucket is configured, but no upload API, identity review, or high-value verification exists. Password login is not transaction 2FA. No financial endpoint is exposed before the required authorization flow is designed. All seven assignment feature groups remain in [REQUIREMENTS.md](../REQUIREMENTS.md) and [SCOPE.md](../SCOPE.md).

The shared policy directory `D:\Data\Downloads\Policies` was unavailable when rechecked on 2026-10-20. No contents were read or policy compliance claimed.
