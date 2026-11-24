# Isolated browser session-handoff probe

Test support for BR-04, not the Nene demo or Flutter integration. This harness runs the installed `gotrue 2.27.3` Dart package in two Edge tabs. HTTP responses and session tokens are synthetic; browser BroadcastChannel delivery and SDK mutation behavior are real. It performs no provider calls, writes no banking data and stores no session in local/session storage. Do not claim provider authentication or a complete safe handoff from these checks.

Compile from the repository root using the existing locked app package configuration:

```powershell
New-Item -ItemType Directory -Force -Path .tmp/session-handoff-web | Out-Null
Copy-Item -LiteralPath experiments/session_handoff_web/index.html -Destination .tmp/session-handoff-web/index.html
.tools/flutter/bin/cache/dart-sdk/bin/dart.exe compile js --packages=app/.dart_tool/package_config.json -O1 -o .tmp/session-handoff-web/probe.js experiments/session_handoff_web/probe.dart
```

Start the fixture server from the repository root in a separate terminal:

```powershell
node scripts/serve-session-handoff-probe.mjs
```

It serves only the fixed compiled HTML/JavaScript assets from `.tmp/session-handoff-web`, selects a free loopback port in 4179–4199 and prints its origin. It has no API/Auth proxy, repository browsing or LAN binding. It never stops another project's process. Use the printed origin in the steps below. This host required sandbox permission for the loopback server; an `EACCES` result does not establish that every candidate port is occupied.

Stop the owned server with Ctrl+C, or enter `q` when running it with interactive stdin. It also closes connections and stops after 15 minutes. An unattended runner must retain its own process handle for cleanup; do not discover and kill unrelated port owners. No `run.bat`, normal app, Android Studio or emulator is needed.

For automated execution with an already installed Playwright module and installed Microsoft Edge, run this in another terminal (replace the origin with the server's printed value):

```powershell
node scripts/check-session-handoff-web.mjs http://127.0.0.1:4179
```

If Playwright is available only through an existing desktop/tool bundle, pass the absolute path to that bundle's entry module as the second argument. For example, replace this placeholder with the actual installed path:

```powershell
node scripts/check-session-handoff-web.mjs http://127.0.0.1:4179 '<absolute-path-to-installed-Playwright-entry-module>'
```

The runner installs nothing. It launches headless Edge in a fresh context, creates the two pages, restricts page network requests to the fixed fixture assets, checks all five observations and empty local/session storage, then closes its browser in `finally`. It does not reuse a personal Edge profile or stop the separate server. Its sanitized report is written to `.tmp/session-handoff-web-result.json`.

Alternatively, open two Edge tabs manually on the printed origin, with a fresh lowercase run ID:

- `/index.html?run=<unique-run-id>&role=leader`
- `/index.html?run=<same-run-id>&role=observer`

Open the observer within 90 seconds of the leader. The leader runs automatically once both connect. Each case has bounded waits and reports sanitized JSON in `#results`; `body[data-probe-state="complete"]` marks completion. The observer can then be closed. Close both tabs and stop only the owned temporary server after collecting results.

Expected observations:

1. A second in-page Auth client and another tab receive the installed session even without persistent storage.
2. A delayed unguarded `setSession` restores a session after local sign-out and broadcasts it to the other tab.
3. A delayed unguarded `setSession` replaces a later customer's session in both tabs.
4. A prevalidated generation check rejects its own delayed response after logout without installing it.
5. A late SDK event from another client bypasses that local-only import guard and restores the old session through the SDK's internal BroadcastChannel handler.

`observed-as-expected` means the stated behavior was reproduced, including unsafe behavior. It does not mean the browser integration gate passed. The guarded code is a deliberately small test adapter, not production code; it does not implement cryptographic server validation, purpose/revision authorization, refresh coordination or complete broadcast isolation. The exact production adapter remains blocked until those boundaries are proved. AWS is unrelated and undecided.

Recorded execution on 2026-10-27 used installed Microsoft Edge 156 in a fresh headless context. All five expected observations were reproduced; there were no unexpected page network requests or browser script errors, and both pages' local/session storage stayed empty. **The browser integration gate did not pass:** late peer broadcasts still bypass the local generation guard. This is SDK/browser behavior with a fake Auth transport, not live provider recovery, native Android behavior, or production handoff acceptance.
