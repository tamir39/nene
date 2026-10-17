# Nene mobile foundation

Flutter/Dart app for the Android assignment and future iOS compatibility. This base implements only configuration, existing-account sign-in, a backend-provided customer/officer profile, retry/error handling, and sign-out. It does not implement banking accounts, payments, eKYC, transaction 2FA, utilities, maps, or chat. The complete requirements remain in [REQUIREMENTS.md](../REQUIREMENTS.md) and [SCOPE.md](../SCOPE.md).

## Structure

- `lib/config/`: validates public build configuration before initializing services.
- `lib/data/`: Supabase Auth adapter, NestJS profile client, and profile model.
- `lib/session_controller.dart`: session/profile state and request lifecycle.
- `lib/nene_app.dart`: minimal Material 3 sign-in and role-specific profile UI.
- `test/`: configuration, API contract, authorization state, and UI checks.

There is no direct Supabase database or Storage access from Flutter. The app signs in through Supabase Auth and sends its bearer token to NestJS `GET /api/v1/me`. The backend supplies the application role. Neither a role selector nor editable auth metadata grants permissions.

## Public configuration

Copy `config/local.example.json` to ignored `config/local.json` and replace its key with the local Supabase publishable key (or legacy **anon** key). Supply the file with Flutter's `--dart-define-from-file=config/local.json` option. See the root [README](../README.md) for setup and verified commands.

| Setting | Meaning |
| --- | --- |
| `API_BASE_URL` | NestJS URL including `/api/v1`, without a trailing endpoint such as `/me`. |
| `SUPABASE_URL` | Supabase service origin, without `/auth/v1`. |
| `SUPABASE_PUBLISHABLE_KEY` | Public client key only. Never a service-role, secret, or database credential. |

The example uses Android Emulator's `10.0.2.2` host alias. A physical device needs reachable HTTPS services or an explicitly configured local development transport. Release and profile builds require HTTPS. Debug builds allow HTTP only for `localhost`, `127.0.0.1`, and `10.0.2.2`; arbitrary LAN cleartext is rejected. The Android debug network policy is also restricted to local development hosts. iOS has no release cleartext exception.

Configuration values are compiled into the application and are **not secrets**. Missing, invalid, or placeholder configuration displays an unavailable screen without making a network request. Do not commit actual environment files even when they contain only public configuration.

## Authentication boundary

Session persistence is disabled for this base; tokens live in memory and a new app process requires sign-in. The default preferences-based persistence is intentionally unused. Secure platform-backed persistence and a complete timeout/device-security policy must be reviewed before a production release. Supabase Auth is not the assignment's eKYC or transaction-bound 2FA implementation.

Auth HTTP exchanges have a 15-second deadline covering both response headers and body. A deadline closes that request's transport, and a stalled sign-in returns to the sign-in screen. Late responses cannot install an old session or replace a successful retry. Each Auth request uses its own connection client so canceling one request does not interrupt another.

Only existing users with a backend application profile can proceed. Account creation remains an officer workflow to implement later. Use synthetic local test identities during setup; the mobile app has no self-sign-up or role escalation route. API 401 responses clear the profile and return to sign-in; 403, unexpected roles, malformed responses, and cross-user profile responses fail closed.

The application name `Nene`, Android application ID `com.example.nene_app`, and iOS bundle identifier `com.example.neneApp` are development placeholders. Choose the final bank/app name and unique owned identifiers before store configuration. Android signing/publication and any iOS release are separate tasks; the iOS shell requires macOS/Xcode for verification.
