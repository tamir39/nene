# Isolated browser session-ownership probe

This harness supports BR-04 engineering checks before Flutter integration. It compiles the isolated `SessionOwner` into two Edge pages using a fake `AuthPort`; the owner keeps its own memory-only session and never constructs a GoTrue client or subscribes to SDK events. Separate vulnerable GoTrue `2.27.3` control clients prove that real native BroadcastChannel events were delivered while the owners stayed unchanged.

No normal Nene app, provider credentials, banking data or Auth server is used. The custom control channel carries only test commands and synthetic identity/session labels, never session tokens. Token-bearing legacy SDK events are deliberately generated with synthetic tokens to reproduce the prior hazard. This is not a complete production Auth acceptance test or a new web release. AWS remains undecided.

Compile from the repository root with the existing locked app package configuration:

```powershell
New-Item -ItemType Directory -Force -Path .tmp/session-coordination-web | Out-Null
Copy-Item -LiteralPath experiments/session_coordinator_web/index.html -Destination .tmp/session-coordination-web/index.html
.tools/flutter/bin/cache/dart-sdk/bin/dart.exe compile js --packages=app/.dart_tool/package_config.json -O1 -o .tmp/session-coordination-web/probe.js experiments/session_coordinator_web/probe.dart
node scripts/serve-session-coordination-web.mjs
```

The server serves only the two fixed compiled assets, binds a free loopback port in 4179–4199, has no proxy and never stops another project's listener. Use its printed origin. Stop it with Ctrl+C or interactive `q`; unattended execution must retain the owned process handle. A 15-minute timer also stops it. This host may require local sandbox access for loopback listening.

With installed Microsoft Edge and an already installed Playwright module, run in another terminal:

```powershell
node scripts/check-session-coordination-web.mjs http://127.0.0.1:4179
```

If the module exists only in a desktop/tool bundle, append its absolute entry-module path as the second argument. The runner installs nothing and uses a fresh headless Edge context. It restricts page requests to the fixed local assets and closes only its own browser. The sanitized report is `.tmp/session-coordination-web-result.json`.

Manual execution uses two tabs on the same origin:

- `/index.html?run=<fresh-lowercase-id>&role=leader`
- `/index.html?run=<same-id>&role=observer`

Open the observer within 90 seconds. The leader reports nine scenarios in `#results`; completion is `body[data-probe-state="complete"]`. The automated runner adds a real observer reload check after the scenarios and checks empty local/session storage in both pages.

Scenarios:

1. Independent tab logins retain distinct owned sessions and emit no SDK session event.
2. A late SDK broadcast reaches vulnerable controls but cannot undo owner logout.
3. The same broadcast cannot overwrite an owner's later customer login.
4. A delayed owned exchange cannot restore a logged-out session.
5. A delayed owned exchange cannot overwrite an account switch.
6. Peer-owner logout and legacy SDK logout cannot clear an independently owned session.
7. Queued refreshes serialize and consume the latest owned pair.
8. An exchange holds the rotation lease before dispatch and queues refresh behind its adoption.
9. Timeout clears uncertain state; neither the late exchange nor a later SDK event can restore it.

Passing this harness establishes isolated browser ownership and controlled ordering, not actual provider rotation behavior. The separate live-provider experiment checks token lineage and usable refreshes. Production endpoint authorization, security revisions, UI lifecycle integration and Android acceptance remain separate work.
