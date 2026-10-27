# Identity verification options for Nene

Research date: **2026-10-27**. Status: **recommendation, not a confirmed provider decision or working integration**. The user accepts a small pay-as-you-go cost when comparing options; that preference does not authorize account creation, expenditure or biometric collection. No provider account, paid request or identity upload was made for this research.

## Recommendation

Prefer **AWS Rekognition Face Liveness + CompareFaces, with officer-assisted enrollment**, provided a bounded Android/Flutter integration experiment succeeds. This is my engineering judgment for Nene's required flows, modest usage budget and future maintainability, not a claim that AWS is universally best or that the lecturer has approved this implementation.

AWS provides a documented capture-session lifecycle and a separate face-comparison operation. That fits the later operation-bound check better than treating an uploaded photo as verification. The principal cost is the Flutter-to-native capture bridge. **FPT.AI Liveness + FaceMatch is the simpler API alternative** if that bridge or AWS account access is impractical; confirm its capture/replay contract and account terms before choosing it. Neither service establishes a person's claimed name merely by comparing two selfies.

The chosen stack stays Flutter, one NestJS API and Supabase Auth/PostgreSQL/private Storage. A selected verification provider is a supporting integration, not a replacement backend or authentication system.

## PDF scope and the identity baseline

The [PDF](../FinalProject_2026_2027.pdf), p. 2 Business 2, requires eKYC, preserves officer-assisted biometric identification and gives face enrollment/high-value checking as its example. Every financial transaction separately requires 2FA. It does not prescribe a vendor, liveness algorithm, OCR, NFC, government-database lookup or high-value threshold. See [REQUIREMENTS.md](../REQUIREMENTS.md), [SCOPE.md](../SCOPE.md) and the [screen/backend map](IDENTITY_VERIFICATION.md).

For the course baseline, propose an officer establishing which already-provisioned demonstration customer a reference face belongs to, recording that association, and reviewing the enrollment evidence. The electronic method then checks live presence and, when a trusted reference is available, matches that person to it. Later high-value operations require a fresh check against the accepted reference. A customer's self-submitted name/photo pair remains unanchored until the officer's association is established; liveness alone does not prove the name.

This is an **officer-anchored educational identity flow**, not government identity-document authentication. Lecturer interpretation of eKYC depth and whether officers themselves need enrollment remains open. If document authentication is required, revise the collection/method plan explicitly; do not quietly count two matching selfies as document-backed eKYC. Liveness is recommended engineering support for the required face-based flow, not an extra requirement invented from the PDF.

Keep synthetic profile/account details in development. A successful live-person test requires an explicitly agreed, consenting test participant and suitable handling of their biometric evidence; a fake profile name does not make a real face synthetic. Provider fixtures and simulated statuses can exercise UI/error paths, but cannot establish real liveness or final BR-03 acceptance.

## Comparison

Effort ratings are estimates from the current code and public integration contracts, not measured implementation time or vendor accuracy benchmarks.

| Option | What it supplies | Fit and trade-off | Judgment |
| --- | --- | --- | --- |
| Manual photo upload + officer review | Evidence collection, human assistance and review. | Lowest implementation effort; no independent electronic match or reliable fresh-presence check for later high-value operations. | Useful workflow foundation, insufficient alone for our proposed BR-03 completion evidence. |
| Local face recognition, e.g. OpenCV YuNet/SFace | Face detection, alignment and comparison without per-call provider fees. | We own model packaging, server-side inference, threshold evaluation and anti-spoof/capture work. Browser/mobile scores cannot be trusted as the backend decision. Native inference dependencies add maintenance to the current TypeScript service. | More engineering risk than justified by the assignment while a small provider budget is available. No custom-trained model or extra Python service proposed. |
| **AWS Face Liveness + CompareFaces** | Session-based live capture and separate comparison with a reference face. | Moderate backend effort and additional native capture work; no documented first-party Flutter liveness component in the reviewed SDK list. Good match to per-operation session/result ownership. | **Preferred, conditional on the Android integration experiment.** |
| **FPT.AI Liveness + FaceMatch** | Video upload with optional reference-photo comparison through an HTTP API. | Simpler Flutter capture/NestJS multipart integration. We still own capture quality and trustworthy freshness; the reviewed upload contract does not document a provider-issued challenge session. | Best simpler alternative; absence of a documented session is an evidence gap, not proof the provider has no stronger product. |
| Sumsub | Managed verification flow, Flutter plugin, liveness and face matching; broader identity checks available. | Less capture UI work, but higher commercial commitment and more provider workflow/identity-data integration than the scoped baseline needs. | Reconsider if the lecturer requires full document-backed verification or a suitable educational agreement becomes available. |

Sources: [OpenCV recognition tutorial](https://docs.opencv.org/4.13.0/d0/dd4/tutorial_dnn_face.html) and [SFace model/license](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface); [AWS liveness overview](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness.html) and [CompareFaces](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CompareFaces.html); [FPT liveness API](https://docs.fpt.ai/docs/en/vision/api/liveness/); [Sumsub Flutter plugin](https://docs.sumsub.com/docs/flutter-plugin). SFace's directory publishes an Apache-2.0 license; a real local integration still needs the pinned detector, recognizer and runtime licenses reviewed separately. No models were downloaded here.

**Not equivalent alternatives:** Google's ML Kit face detection locates faces/features but explicitly does not recognize people. It could help framing, not replace identity matching. Device Face ID/fingerprint unlocking also does not bind a face to Nene's customer reference or authorize the exact transaction under this design. [Google's capability statement](https://developers.google.com/ml-kit/vision/face-detection).

## Indicative cost

Public figures checked on the research date; no account-specific quote, credits, taxes, selected-region bill or minimum purchase was verified.

| Provider | Published basis | Illustrative small-volume cost / limitation |
| --- | --- | --- |
| AWS | US East (N. Virginia) liveness example: **USD 0.015/check**. Group 1 image-analysis example: **USD 0.001/image**; CompareFaces is in Group 1. AWS counts only the source image for one CompareFaces call. | One liveness check + one comparison is approximately **USD 0.016**: 100 pairs **USD 1.60**, 500 **USD 8.00**, 1,000 **USD 16.00**. Estimate only, excluding extra face-detection calls, retries, other infrastructure/transfer charges and tax. Reprice in the chosen supported region. |
| FPT.AI | Public liveness table lists **VND 1,000/request** below 10,000 requests/month, with an optional reference image. | 100 such requests: **VND 100,000** before unverified extras. Confirm current access, trial allowance, minimum top-up, tax and combined matching terms; the public table is not proof of an enabled student account. |
| Sumsub | Basic lists **USD 1.35/verification** with **USD 149 minimum monthly commitment**; face authentication is separately listed at USD 0.35/session. A 14-day/50-check trial is advertised. | The monthly minimum dominates a small project. Confirm feature entitlements and current additional-verification pricing; do not assume the trial covers the whole remaining project or repeated checks. |

Sources: [AWS pricing](https://aws.amazon.com/rekognition/pricing/) and [billing-unit FAQ](https://aws.amazon.com/rekognition/faqs/); [FPT liveness pricing](https://docs.fpt.ai/docs/en/vision/documentation/liveness-pricing/) and [trial entry points](https://fpt.ai/try-for-free/); [Sumsub pricing](https://sumsub.com/pricing/). FPT.AI's API offering is not interchangeable with the separately quoted FPT-eID packages. Future provider use should have application rate/attempt limits and a small agreed test allowance; a cost estimate is not a spending cap.

Sumsub's [SDK action guidance](https://docs.sumsub.com/docs/applicant-actions-ios) deprecates the old Face authentication action type in favor of regular applicant actions with advanced liveness. Its listed price does not establish the exact current repeat-matching integration or entitlement; confirm those if reconsidering this option.

## Why AWS first, and what it changes

**Fresh check and server authority.** AWS documents a unique session for each liveness check, a three-minute session lifetime and backend result retrieval. These are useful primitives for Nene's own binding to the customer, evidence revision and exact operation. Nene must still enforce that binding, reject expiry/reuse and consume authorization correctly; a provider session does not implement the banking rules. [Session API](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CreateFaceLivenessSession.html), [backend lifecycle](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness-programming-api.html).

**Small native integration inside Flutter.** The documented capture components are Android, Swift and React. On Android, use a narrowly scoped native capture screen called through a Flutter platform channel; a future iOS adapter would use Swift. This adds some Kotlin to the existing Flutter host, not a framework rewrite. The Android component uses Compose and supports a custom credentials provider, so Supabase can remain the login system. [AWS Android integration](https://ui.docs.amplify.aws/android/connected-components/liveness), [Flutter platform channels](https://docs.flutter.dev/platform-integration/platform-channels).

Read-only compatibility check: Nene's installed Flutter defaults to Android API 24, which matches the documented AWS component minimum. The app currently uses AGP 9.1.0, Kotlin configuration 2.4.0 and Java 17; it has no Compose/liveness dependency. Matching the minimum OS does **not** prove build compatibility. Adapt dependency/compiler configuration in the experiment instead of copying the older versions in the provider's examples. No build or dependency installation was performed for this comparison.

**Keep durable identity data in the current architecture.** NestJS can use the [AWS JavaScript SDK](https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/client/rekognition/). AWS can return reference-image bytes without an S3 output bucket; the backend can preserve the approved reference privately in Supabase. A face collection/search index is unnecessary for one-to-one comparisons. This does not mean AWS never processes or retains content under its own service terms. Review processing location, retention, notice and training opt-out settings before any real-person test. [Result-storage options](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CreateFaceLivenessSession.html), [AWS liveness privacy information](https://docs.aws.amazon.com/ai/responsible-ai/rekognition-face-liveness/overview.html).

Proposed flow after method approval:

1. Officer-assisted enrollment establishes the reference-to-customer association; customer capture and officer review use the existing C16/O06 design. Choose the precise enrollment evidence steps before collection.
2. NestJS authorizes the case or financial intent, creates a liveness session and records its owner/purpose/revision. Only short-lived, narrowly permissioned capture credentials reach the native component; no permanent provider secrets in Flutter.
3. The official component streams capture to AWS. Its completion callback merely prompts a backend lookup; it is never a trusted pass result. This would be an explicit method-specific exception to the map's generic NestJS upload path, limited to provider capture. Banking reads/writes stay in NestJS.
4. NestJS retrieves the matching result before expiry, evaluates the liveness policy and compares the reference frame with the officer-anchored reference where required. Validate one usable face, image limits and failed/unknown results. A score is probabilistic, not a percentage guarantee of identity; select thresholds with positive/negative checks rather than copying the API's default 80 similarity filter. [CompareFaces behavior](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CompareFaces.html).
5. Persist minimal result metadata and the necessary private reference. Enrollment requires the configured electronic check plus the officer decision. A later high-value result is tied to that operation only and still leads to **separate transaction 2FA**. Provider failure or missing data leaves verification incomplete.

The provider's capture UI limits how closely that one step can match our custom screens. Nene's lighter identity remains on instructions, review, status and officer views; supported SDK theming can be explored in the experiment. A different provider later requires capture and evidence migration work even with a small backend adapter; do not promise a zero-cost swap.

## FPT.AI fallback: what must be proved

Its documented endpoint accepts a 5-6 second MP4 video, at least 720p/25fps and no more than 10 MB, plus an optional reference image up to 5 MB. It returns distinct liveness and match results. The request is straightforward to send from NestJS after authorization. [Input/result contract](https://docs.fpt.ai/docs/en/vision/api/liveness/).

However, a previously recorded genuine video can remain a live-looking video. Our own short-lived operation token binds a request, but does not prove the recording was made for that request. Require provider confirmation or an evaluated capture mechanism for freshness/replay before treating it as a strong high-value check. The public contract alone cannot establish resistance to every replay/injection attack. This is the principal reason to prefer AWS's documented session/challenge workflow, not a comparative accuracy claim.

Also verify accepted reference-photo use, input/header details and response parsing with authorized API access. Overall response success does not mean `is_live` and `isMatch` passed; examples contain string-valued booleans and review warnings. A selected video-upload method would require revising the map's image-only limits and transient video handling; do not silently open the current private bucket to arbitrary video types. No FPT requests or sales messages were sent.

## Testing and decision gate

For now, the existing Edge preview can test future status, correction and officer layouts using explicitly labeled fixtures. **Actual capture needs a physical Android test in the proposed AWS path.** The current Flutter web preview does not embed AWS's React component. Browser camera access also requires a secure context: localhost may work, but an ordinary `http://<LAN-IP>` page on a phone is not sufficient. Do not weaken browser settings or the native network policy to bypass that. [Browser camera contract](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia).

Before confirming this provider for implementation:

- Compile/open/close the Android capture bridge with Nene's actual toolchain; check camera denial, background/resume and cancellation. Preserve the lighter surrounding UI. No iOS release or second web application is added.
- With separately authorized account/access and test data, prove a server-created session, trusted result retrieval, matching and non-matching faces, expiry, duplicate completion and wrong-user/operation rejection. Failed liveness and replay attempts must not become verified results. Limited tests establish our integration behavior, not a general biometric accuracy guarantee.
- Confirm region, billing and evidence-handling policies. Ensure approved results are copied before provider session expiry and that unavailable results remain unavailable. Keep cost/attempt controls in NestJS and use a minimal credential design; do not automatically provision Cognito users or a second application database.
- Set the enrollment pass criteria, high-value threshold, retention/attempt policies and transaction-2FA method separately. Resolve lecturer expectations for the officer-anchored demonstration and officer enrollment. Any required document verification changes the plan and must be recorded.

If the Android bridge fails this bounded feasibility check, evaluate FPT.AI against the unresolved freshness and access points before switching. Do not default to a fake pass or manual approval and report BR-03 complete.

Evidence limits: official public docs and pricing were inspected; local Android configuration and the existing screen/backend map were read. No commercial eligibility, latency, actual charge, live biometric accuracy, capture compatibility, external account state or end-to-end provider behavior has been verified. The shared `D:\Data\Downloads\Policies` folder remained unavailable. The recommendation leaves the current implementation and authoritative assignment files unchanged.
