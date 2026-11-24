# Android build cache failures

Diagnosis on 10 November 2026 supports Android delivery (TR-02); no banking behavior or PDF scope changes.

The Android Studio log reported missing Dart package files under the Windows Pub cache (`http`, `latlong2`, `supabase_flutter`, `image_picker`, `vector_math`). The earlier Java native-access messages were warnings, not this failure. Restore the exact locked packages from `app/`:

```powershell
..\.tools\flutter\bin\flutter.bat --no-version-check pub get --enforce-lockfile
```

The restore succeeded without changing `pubspec.yaml` or `pubspec.lock`. All absolute package directories referenced by the regenerated package configuration exist. The reason those cached packages disappeared is unknown.

The subsequent Android build exposed a separate Kotlin error in `package_info_plus` and `image_picker_android`: `this and base files have different roots`. The Pub cache is on `C:` and the project is on `D:`. Project-local `android/gradle.properties` now sets `kotlin.incremental=false`, the [documented Kotlin/JVM setting](https://kotlinlang.org/docs/gradle-compilation-and-caches.html) for disabling incremental compilation. This avoids the failing relative-path cache. Kotlin recompilation may be slower; this does not disable all Gradle caching or alter user-wide Gradle/Java settings.

Verification command, from `app/`:

```powershell
..\.tools\flutter\bin\flutter.bat --no-version-check build apk --debug --no-pub --dart-define-from-file=config/local.json
```

Android Studio's Flutter run configuration also needs `--dart-define-from-file=config/local.json` in its additional run arguments when testing against the existing emulator configuration. A plain `lib/main.dart` launch without configuration can compile but shows the configuration-required screen. The local API/Auth/database must be running separately; the existing user-started `run.bat` supplies that stack. Keep private/local configuration and the launcher uncommitted.

Verification passed: the debug APK built successfully in 43.1 seconds at `app/build/app/outputs/flutter-apk/app-debug.apk`. The build also installed the required CMake 3.22.1 using the SDK's already accepted license. The Java native-access warning remains nonfatal. No dependency versions changed. Installing/launching the APK, login and financial flows are separate checks. No emulator or demo was launched by this repair. The shared policy folder remains unavailable; no unseen policy compliance is claimed.
