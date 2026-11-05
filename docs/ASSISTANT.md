# Activity-linked assistant

Implemented 5 November 2026 for **BR-14**, PDF p. 2, Business 7. The source requires conversational answers with links to activities, including phone services, bills and monthly transactions. No particular AI vendor/model is prescribed. This slice implements a bounded intent-based assistant and existing activity links; it does **not** complete bill/top-up links or full BR-14 acceptance.

## Implemented behavior

Customer home → **Ask Nene** opens an in-session chat using the existing Flutter identity and palette. Customers can type English or Vietnamese questions; replies are in English. A small deterministic interpreter in NestJS recognizes supported requests, asks for a missing/ambiguous history month, and returns typed activity descriptors. It is rule-based language handling, not a generative model or unrestricted financial adviser.

| Request | Result |
| --- | --- |
| `Show transactions for October 2026`, `History 2026-10`, `Xem lịch sử tháng 10/2026` | Open history for `2026-10` → choose one of the customer's accounts → existing posted-history screen with that month selected. |
| `Show my history`, then `October 2026` | Ask which month, retain a bounded history-month follow-up context, then offer the correct link. |
| `Transactions this month`, `lịch sử tháng trước` | Resolve the month on the backend using UTC+07, including year rollover. |
| `Transfer money`, `chuyển khoản` | Open the existing local same-bank transfer form after choosing an eligible VND checking account. |
| `Deposit money`, `rút tiền` | Open the existing simulated cash deposit/withdrawal form after choosing an eligible VND checking/saving account. |
| Phone top-up, electricity/water bill or other-bank transfer request | Explain that the relevant flow is not implemented. No fake payable screen, payment action or success result. |
| Multiple recognized activities, invalid/full date, missing year, unsupported request | Clarify the activity/month or explain the supported requests. No guessed financial operation. |

Explicit history dates support `YYYY-MM`, `MM/YYYY`, English full/three-letter month plus year and `thang M [nam] YYYY`. Years follow the existing history contract, 2000–2100. Unsupported phrasing may need rewording; this is not a general language model. A bare month without a year is not silently assigned to the current year.

Activity buttons never submit money movement, select a recipient, prefill an amount, seed funds or generate transaction authorization. The customer chooses an account from the backend-owned account list and enters details in the ordinary form. Existing local enablement, funds, reference, threshold, review and transaction-bound TOTP checks still apply. Financial links return to chat through the existing Back action; normal Home history links continue to start with the current month.

Chat has loading/error/retry and clear-conversation states. It retains at most 40 messages in memory while the current customer workspace is active. Retry does not duplicate the failed customer message. Sign-out/session change clears messages and rejects late responses; clearing chat also discards an in-flight result. Returning from an activity retains the current conversation. There is no persistent transcript, background agent, voice feature, investment advice, autonomous payment or external AI provider.

## API and authorization

`POST /api/v1/me/assistant/messages` requires a valid active customer session. Officers are denied. The global Supabase session/profile boundary is unchanged. Responses send `Cache-Control: no-store`.

Request: `{ "message": "history October 2026", "context": "history_month" }`. Context is optional/null and only that enum value is accepted. The server accepts a nonblank message of at most 500 UTF-16 code units; other properties, unsupported context and control characters are rejected with 400. Context is a conversation hint, never permission.

Response: `{ "reply": "...", "actions": [{ "type": "history", "month": "2026-10" }], "context": null }`. The only action types are `history`, `transfer`, `deposit` and `withdrawal`. Only history has a month. There are no client-selected account IDs, provider URLs, arbitrary paths or financial payloads. Flutter validates the response and action allowlist before rendering plain text and local navigation buttons. Transport disables redirects, bounds responses to 16 KiB and applies a 15-second timeout.

The interpreter has no database/service/provider dependency: after normal session/profile authorization, it cannot read private banking records or mutate anything. The destination APIs still independently enforce ownership and financial rules. Questions about another customer's history and obvious credential/URL/account-number input receive a neutral explanation; this is not a guarantee of detecting every sensitive string. The UI asks users not to enter such data. Messages are not written to application logs, database or external AI services; no new storage or credentials are added.

## Verification

- Backend lint/build and **113 tests** pass; formatting passes. New pure and HTTP tests cover English/Vietnamese dates, missing/ambiguous/invalid months, UTC+07/year rollover, follow-ups/context switching, unsupported services, sensitive input, forged payloads, session requirements and officer denial. HTTP tests use Auth/profile fakes and reject unexpected banking queries; they are not a real Supabase test.
- Flutter analysis, all **216 tests** and the debug web build pass. The 11 new assistant tests cover action validation, retry, session clearing, bounded memory, history navigation/month preservation, no-account state, large text and all three financial-form handoffs without posting. A 390-pixel synthetic conversation capture was rendered and visually inspected; it is widget evidence, not live Edge/Supabase or Android acceptance.
- No schema/grant or provider configuration changed. No new database fixture is required for the deterministic interpreter; existing account/history/confirmation endpoints retain their prior verification limits.
- The user will test interactively later. No Docker/demo server, emulator or Android Studio was started. Branch PR #29 remains a draft with its database/interactive checks pending. The unavailable shared `D:\Data\Downloads\Policies` bundle was checked again; no compliance claim is made.

When the user chooses to test, start/restart local `run.bat`, sign in as a customer, choose **Ask Nene** and try the examples above. Check that a history link preserves its month after selecting an account, Back restores the conversation, and sign-out clears it. Opening a financial link must only open its ordinary form; bill/top-up requests must clearly remain unavailable. The launcher remains local-use and uncommitted.

## Remaining PDF work

Connect real bill/phone-service destinations when those required flows are implemented. Confirm the assistant's demonstrated conversational adequacy during human/lecturer acceptance; a fixed example response or unlinked FAQ alone is not the complete requirement. Full Android, hosted/session and human end-to-end acceptance remain open.

Face comparison itself and AWS stay undecided. Existing high-value posting remains blocked and reference acceptance is not completed eKYC. Branch-map testing stays deferred as requested. No additional product or AI platform is introduced.
