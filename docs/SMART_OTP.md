# Nene Smart OTP

Added 26 November 2026 (app 1.0.3) as BR-04 support: customers can confirm payments and transfers with their fingerprint or the phone's screen lock instead of typing a code from a separate authenticator app. **The server is unchanged.** It still checks an ordinary TOTP code bound to the reviewed operation, as described in [TRANSACTION_CONFIRMATION.md](TRANSACTION_CONFIRMATION.md) and [LOCAL_TRANSFERS.md](LOCAL_TRANSFERS.md). Smart OTP is an authenticator built into the Nene app.

## How it works

- **Setup.** On **My profile → Transaction security**, an Android phone with a screen lock offers **Use Smart OTP on this phone** next to the manual setup key. After the fingerprint / screen-lock prompt, the app saves the key and sends its first code to the normal verify endpoint, so nothing is typed. The manual key is still shown, so the same key can also be added to an authenticator app.
- **Replacement and recovery.** When a replacement key is shown in **Manage authenticator and recovery**, the same button moves Smart OTP to the new key. If the server definitely rejects the code, the previous Smart OTP key is restored. If a code is typed instead, any old Smart OTP key on the phone is removed, because its authenticator is being retired. Other code fields in that screen offer **Fill with Smart OTP**.
- **Confirmation.** Transfers, deposits, withdrawals and VNPay checkouts show **Confirm with Smart OTP** under the code field when the phone holds a key for the signed-in customer. The prompt unlocks the key, the app computes the code and submits it like a typed one. Large transfers still need the face check first.
- **Turning it off.** Transaction security has **Turn off Smart OTP on this phone**, with a warning that a recovery code is needed if no other authenticator holds the key.

## Code generation

`app/lib/data/totp.dart` implements RFC 6238 with the Supabase Auth TOTP parameters: base32 key, HMAC-SHA1, 30-second steps and 6 digits. It is tested against the RFC 6238 appendix B vectors. The server accepts each code once, so the app never offers the same 30-second step twice for one key. A second confirmation in the same step waits for the next one, up to 30 seconds.

## Storage and its limits

- The key is stored with `flutter_secure_storage` (AES-GCM, wrapped by an Android Keystore key), one entry per signed-in user ID. Android backup is disabled (`android:allowBackup="false"`) so the encrypted entry is never restored onto another device.
- The key is read only after `local_auth` reports a successful fingerprint, face or screen-lock (PIN, pattern, password) prompt. **The prompt is enforced by the app; the key is not cryptographically bound to the fingerprint.** A rooted or compromised phone could read it. Banking apps with certified Smart OTP add hardware-bound keys, device binding and server-side device registration. Nene does not claim those.
- Smart OTP is Android only. Web and desktop previews never offer it. The key stays on the phone after sign-out, like a bank Smart OTP, and is never sent to Nene's server again.
- Device unlock alone does not replace transaction 2FA: the server still requires the TOTP code, now produced by the phone that holds the key.

## Android changes

`MainActivity` extends `FlutterFragmentActivity` (required by `local_auth`). The manifest adds `USE_BIOMETRIC`. The launch theme uses `Theme.AppCompat.Light.NoActionBar`, with `androidx.appcompat:appcompat:1.7.1`, to avoid prompt crashes on Android 8 and below. Dependencies are pinned: `local_auth 3.0.2`, `flutter_secure_storage 11.2.0`, `crypto 3.0.8`.

## Verification

- `app/test/smart_otp_test.dart`: RFC vectors, base32 parsing, unavailable platforms, cancelled prompts, malformed keys, step reuse, restore/keep/remove, and widget flows for a transfer, setup (success, rejection, preview) and replacement (Smart OTP, rejection, typed code).
- The debug APK builds, and its merged manifest contains `USE_BIOMETRIC` and `allowBackup="false"`.
- **Not yet verified on a physical phone:** the fingerprint prompt, Keystore storage and a live transfer confirmed with Smart OTP need the 1.0.3 build on a device.
