# VNPay sandbox access and callback setup

Decision/check date: **2026-11-05**. The user selected **VNPay PAY sandbox hosted checkout** for BR-10 (PDF p. 2 Business 4), and asked to check credentials/callback setup before integration. Face comparison and AWS remain undecided. This is a setup plan; no merchant account, callback, payment route or tunnel has been created.

The user confirmed they have neither an ngrok account nor a public HTTPS address. Recommend a free ngrok development domain for local callback testing; this is development connectivity, not a new application feature or backend. Account creation remains with the user. No paid domain, live merchant contract or production payment is needed for the proposed sandbox exercise.

## User steps and exact registration fields

1. Create a free account through [ngrok's dashboard](https://dashboard.ngrok.com/signup), verify the email and obtain the assigned development hostname. Share only that public hostname with the project; keep the password and agent authtoken private. Do not start a generic tunnel to the Nene preview or API yet.
2. Prepare the [VNPay test merchant registration](https://sandbox.vnpayment.vn/devreg). The indexed official form has the fields below. Direct page retrieval timed out during this review, so live validation, acceptance of a tunnel hostname and email issuance are not verified.

| VNPay field | What to enter |
| --- | --- |
| Ten website / Tên website | `Nene - university sandbox demo` (a descriptive project name, not a claim to operate a real bank). |
| Dia chi URL / Địa chỉ URL | The actual public HTTPS project/demo address after its restricted endpoint is prepared. Do not invent a domain or use a localhost/LAN address as a public callback. The registration website address is distinct from the IPN route. |
| Email dang ky / Email đăng ký | An email the user controls and can receive VNPay messages at. |
| Mat khau / Mật khẩu; repeat password | A new private password for the test merchant portal. This is not the payment signing secret. |
| Ma xac nhan / Mã xác nhận | Complete the CAPTCHA personally in the form. |

3. Submit the registration once the public address is ready, then follow the actual email/account instructions. VNPay's PAY docs say connection details are emailed to the registered address. Keep `vnp_TmnCode` (terminal/site ID) and `vnp_HashSecret` (signing secret). Do not paste the secret or complete credential email into chat or a PR. The form reviewed does not request live bank/card credentials; do not turn this into production onboarding.
4. Once the IPN handler is implemented and checked, provide its exact URL through the configuration/support process supplied with the sandbox credentials. The PAY guide says to give VNPay the IPN URL after implementation. The reviewed registration form has no separate IPN field; do not assume entering the website address registers callbacks. If the email/portal offers no such control, ask VNPay sandbox support to configure the terminal's IPN URL. No support message has been sent.

Sources: [official registration form](https://sandbox.vnpayment.vn/devreg), [PAY configuration guide](https://sandbox.vnpayment.vn/apis/docs/thanh-toan-pay/pay.html). The indexed form was crawled approximately four weeks before this review; the integration guide is older. Actual account access remains to prove. No promise of immediate issuance or acceptance of an ngrok domain is made.

## The three different URLs

These are **proposed paths**, not working endpoints. Replace `PUBLIC_HOST` with the actual assigned hostname only after configuration; do not submit literal placeholders.

| Address | Purpose and reachability |
| --- | --- |
| `https://PUBLIC_HOST/` | Minimal public project/demo information for the registration website address. This is not the full Flutter web app and must expose no private data. Subject to VNPay accepting that project URL. |
| `https://PUBLIC_HOST/api/v1/payments/vnpay/ipn` | VNPay server-to-server payment notification. Official PAY docs specify GET and SSL. Must be reachable without an interactive login or browser challenge. Validate the provider signature and payment record; it does not use a customer Supabase session. |
| `https://PUBLIC_HOST/api/v1/payments/vnpay/return` | Browser return supplied as `vnp_ReturnUrl` in the payment request. A minimal page tells the customer to return to Nene and check status. It must not mark a payment paid just because the browser arrived. |

IPN confirms the backend result; Return URL handles browser navigation. The provider contract also specifies checking checksum, order, amount and prior state before responding with `RspCode`/`Message`. Duplicate notifications are expected and must not duplicate results. [VNPay PAY contract](https://sandbox.vnpayment.vn/apis/docs/thanh-toan-pay/pay.html).

Keep the current Nene tab open during Edge checkout so its memory-only session survives. If it is refreshed/closed, re-login and fetch the owned payment record. Do not add tokens to callback URLs or introduce persistent sessions merely for checkout. Native Android return behavior is separate later acceptance work.

## Smallest callback arrangement

Proposed path: **VNPay -> public HTTPS endpoint -> strict method/path allowlist -> existing loopback NestJS API**. The allowlist must deny everything except the intended GET IPN/return routes, with the root project-information page served separately as static non-sensitive content. No new banking backend or application database is introduced.

The free ngrok plan currently includes an assigned account-bound development domain that survives agent restarts, HTTPS with certificates and traffic-policy rules. Browser HTML may show an ngrok warning page; ngrok says programmatic/API traffic is not affected. Verify actual VNPay delivery rather than relying on that statement. The public address only serves the local app while the required process is running. [ngrok free-plan documentation](https://ngrok.com/docs/pricing-limits/free-plan-limits).

Use ngrok's request policy to reject other paths/methods before forwarding; a custom response can terminate a rejected request. This is a proposed restriction, not a tested configuration. Keep signature verification in NestJS rather than assuming a generic tunnel webhook verifier supports VNPay. [ngrok custom responses](https://ngrok.com/docs/gateway/traffic-policy/actions/custom-response).

Do not expose the general `/api/v1` tree, officer/customer/identity/security routes, Flutter dev server, Auth proxy, Storage or database. Keep existing ports (preview 4179-4199, API 3001-3005, loopback Supabase 45320-45324) and never stop another project's listener. Prefer the existing assigned API port; no new local port is allocated in this check. Do not broaden `LOCAL_BROWSER_PREVIEW` to public origins.

The ngrok service sees test callback traffic; use synthetic payment references and no real customer details. Configure request inspection/logging deliberately before testing so payment payloads are not copied into general logs. Keep the user's agent token private. An HTTPS hostname alone is not verified callback readiness.

## Backend credential/configuration placement

The intended configuration consists of the terminal ID, signing secret, sandbox payment endpoint, Return URL and externally registered IPN URL. Portal passwords and ngrok agent tokens are not application payment credentials.

`backend/.env.local` is already ignored by Git and is the appropriate local backend configuration location. Future integration will define validated variable names; none are consumed by the application yet. Do not place the signing secret in Flutter config, source control, URLs, command output or screenshots. No secret file was read or modified in this check.

## Readiness and next work

| Item | Status |
| --- | --- |
| VNPay PAY sandbox choice | Confirmed by user. |
| ngrok account / public hostname | User has neither; suggested account/domain setup is pending. |
| VNPay registration, terminal ID and secret | Pending user action; no credential values inspected. |
| IPN registration for that terminal | Pending actual account instructions and a working handler. |
| Narrow public endpoint and browser return | Planned only; no tunnel started. |
| NestJS payment adapter, signature checks and result persistence | Not implemented. |
| Provider-sandbox success/failure/retry evidence | Not run. |

Next engineering work is a bounded sandbox adapter and restricted callback/return setup, followed by signature, wrong-order/amount, duplicate and failure tests. The user continues starting `run.bat` for interactive app testing; local runner changes remain uncommitted. Do not request a test payment until callback isolation and terminal configuration are checked.

This covers BR-10 setup and BR-04 support only. Nene TOTP remains separate from VNPay's test-bank OTP; preserve the existing high-value block and identity policy. External checkout is not an automatic Nene deposit/debit, interbank transfer or fulfilled bill. Scope, sandbox acceptance and actual eKYC remain as in the [scope audit](SCOPE_STATUS_AUDIT.md).

Verification: reviewed official/indexed VNPay form and PAY documentation, current ngrok documentation, local API prefix/configuration, launcher port conventions and Git ignore rules. No live form submission, callback reachability, payment, account creation or runtime test occurred. The shared policy folder remains unavailable; no policy compliance is claimed. Original assessment files and local-only tooling are unchanged.
