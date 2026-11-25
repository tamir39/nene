# Google Play release

Added 24 November 2026 for TR-04. The user chose the **closed testing** track: a new personal Play account cannot reach production before the 1 December deadline (12 testers for 14 days). The lecturer will be told about the testing stage and added as a tester. This is not full public availability.

## Identity

| Item | Value |
| --- | --- |
| Application ID | `vn.nene.bank`, permanent after the first upload |
| Launcher name | Nene |
| Store title (proposed) | Nene – Student Banking Demo |
| Version | `1.0.2+3` in `app/pubspec.yaml` (earlier internal-testing uploads: 1.0.0+1, 1.0.1+2); raise the `+N` build number for every upload |

The iOS bundle identifier remains a generated placeholder; no iOS release is planned.

## Upload key

Google Play App Signing holds the app-signing key. Nene keeps only an **upload key**:

- Keystore: `C:\Users\PC\.nene-release\nene-upload.jks` (outside the repository), alias `upload`, RSA 4096, valid until 2054.
- Passwords: the ignored `app/android/key.properties`, with a backup copy beside the keystore. They were generated randomly and never displayed.
- Back up the whole `.nene-release` folder privately. If it is lost, request an upload-key reset through Play Console.

Without `key.properties`, `flutter build appbundle --release` fails rather than signing with the debug key.

## Build

1. Copy `app/config/release.example.json` to the ignored `app/config/release.json` and set the hosted API, the Supabase URL and the **publishable** key only. The API must be the deployed [hosted sandbox](HOSTED_DEMO.md).
2. From `app/`:
   ```powershell
   ..\.tools\flutter\bin\flutter build appbundle --release --dart-define-from-file=config/release.json
   ```
3. Upload `app/build/app/outputs/bundle/release/app-release.aab` to the closed testing track.

## Verification so far

- 24 Nov: a signed release bundle built in about 3 minutes (54 MB). `keytool -printcert` confirms the upload-key certificate. Flutter could not strip native debug symbols, likely a missing NDK component; Play still accepts the bundle.
- That build used a provisional API address; rebuild once the Render URL is known.
- Not yet verified: installation on a phone, store listing, data-safety form, financial-features declaration, reviewer access and Google review.
