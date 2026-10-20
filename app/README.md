# Nene mobile app

Flutter/Dart app for the Android assignment and future iOS compatibility. The first customer flow supports officer customer creation with an initial account, officer search and customer-requested profile edits, customer account viewing and phone/address edits, existing-account sign-in and sign-out. The approved lighter Open pocket identity is shared across these screens. Money movements, eKYC, transaction 2FA, saving/mortgage management, utilities, maps and chat remain unimplemented. The complete requirements remain in [REQUIREMENTS.md](../REQUIREMENTS.md) and [SCOPE.md](../SCOPE.md).

## Structure

- `lib/config/`: validates public build configuration before initializing services.
- `lib/data/`: Supabase Auth adapter, NestJS profile/banking clients, and typed models.
- `lib/session_controller.dart`: session/profile state and request lifecycle.
- `lib/customer_flow_controller.dart`: account/contact/customer request state and creation retries.
- `lib/nene_app.dart`: Material 3 sign-in and session boundary.
- `lib/ui/`: shared lighter theme/logo and the role-specific customer workspace.
- `test/`: configuration, API contract, authorization state, and UI checks.

There is no direct Supabase database or Storage access from Flutter. The app signs in through Supabase Auth and sends its bearer token to NestJS. The backend supplies the application role, account type, currency and balance; the client cannot choose these in a creation request. Neither a role selector nor editable auth metadata grants permissions.

The first demo defaults are one VND checking account with a zero balance. Account amounts use string-encoded integer minor units and are displayed without floating-point conversion. A missing/failed account response never becomes a zero balance. Customers edit only phone/address; officers can make a requested name/phone/address change with a reason. Sign-in email is read-only after creation. These are provisional design choices, not additional PDF requirements.

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

Only users with a backend application profile can proceed. Officers can provision synthetic demo customers from their workspace; the mobile app has no self-sign-up or role escalation route. API 401 responses clear protected state and return to sign-in. All protected pages live inside the session subtree, so expired or signed-out sessions cannot navigate back to customer details. Cross-user profile responses and unexpected roles fail closed.

Returning from the background or refreshing a token revalidates the current profile without discarding an unfinished form or pending creation for the same principal. A transient revalidation failure retains the already loaded workspace; each API operation remains independently authorized by NestJS. A real user/role change, sign-out, rejected profile or expiry clears the workspace, and late request responses cannot repopulate it.

Creation has a review step. Its initial password is masked, never logged or persisted, and absent from the creation response. The first submit generates a random UUID `Idempotency-Key`; uncertain retries retain the exact original body and key in memory. Only validation rejection or the backend's confirmed `CUSTOMER_EMAIL_EXISTS` code permits editing and starting a corrected attempt. Buttons prevent duplicate submits. Success and workspace disposal release password references. This is not secure session/draft persistence: after process death or sign-out, an officer must check the customer by email before attempting another creation; unresolved provisioning may need backend reconciliation. No invitation email or password-reset workflow is implemented.

The application name `Nene`, Android application ID `com.example.nene_app`, and iOS bundle identifier `com.example.neneApp` are development placeholders. Choose the final bank/app name and unique owned identifiers before store configuration. Android signing/publication and any iOS release are separate tasks; the iOS shell requires macOS/Xcode for verification.
