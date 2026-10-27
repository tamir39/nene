# Identity verification options: background research

Research and decision update: **2026-10-27**. **No provider is selected or preferred.** The user chose to simplify the flow and leave AWS undecided. This supersedes the earlier AWS-first recommendation and removes its native capture experiment from the immediate next task. The [private reference foundation](REFERENCE_FLOW.md) is now implemented; no face-comparison or liveness integration has been implemented or provisioned.

## Current direction

Follow the [minimum identity flow](IDENTITY_VERIFICATION.md): private reference enrollment with officer assistance/acceptance, actual server-side one-to-one comparison for later high-value activity, and separate transaction 2FA. Build the reference foundation before selecting the comparison implementation. Keep Flutter, one NestJS API and Supabase Auth/PostgreSQL/private Storage.

The [PDF](../FinalProject_2026_2027.pdf), p. 2 Business 2, requires eKYC, officer biometric assistance and transaction 2FA; face enrollment and high-value verification are its example. It does not mandate AWS, commercial KYC, document OCR/NFC or advanced liveness. Those may become deliberate choices if a concrete course requirement or future security need justifies them. Reference acceptance alone cannot complete BR-03, and an ordinary photo comparison must not be described as proof of live presence or government identity.

The user accepts a small pay-as-you-go cost as a comparison constraint. That does not authorize opening accounts, paying for checks or collecting biometric data. No such actions were taken during this research.

## Options to revisit when implementing actual matching

| Option | What it supplies | Cost/effort to evaluate, without a ranking |
| --- | --- | --- |
| Manual photo upload and officer review | Reference collection and association with an existing customer. | Implemented foundation slice. It supplies no automated high-value match, so it is not a substitute for the comparison step. |
| Server-side photo-comparison API | One-to-one comparison of an accepted reference and a submitted capture, called by NestJS. AWS CompareFaces and FPT.AI FaceMatch are examples. | Assess access, per-call cost, backend-only credentials, input limits, meaningful thresholds and match/mismatch results. A comparison-only API does not require selecting the same vendor's native liveness SDK. It also does not establish capture freshness. |
| Local recognition, e.g. OpenCV YuNet/SFace | Detection/alignment/comparison without a provider fee per call. | Evaluate runtime/model licensing, inference integration and maintenance. Do not train a custom model or add a separate service by default. Client-supplied match scores cannot be authoritative. |
| AWS Face Liveness with CompareFaces | Session-based liveness plus comparison. | Additional capture/credential/platform work. AWS's reviewed capture components are Android, Swift and React; Flutter integration remains unproven. This is an optional stronger path, not the next scheduled experiment. |
| FPT.AI Liveness with matching | Video-upload liveness and optional reference comparison. | Additional video handling, capture quality and freshness/replay questions. The published upload contract alone does not prove trusted fresh capture. No fallback order is assigned. |
| Sumsub | Managed verification and a Flutter plugin with broader identity checks. | Assess commercial commitment and collection requirements only if that breadth becomes necessary. It is not the minimum enrollment prerequisite. |

Primary sources inspected during the earlier research: [AWS CompareFaces](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CompareFaces.html), [FPT FaceMatch](https://docs.fpt.ai/docs/en/vision/api/face-match/), [OpenCV tutorial](https://docs.opencv.org/4.13.0/d0/dd4/tutorial_dnn_face.html), [SFace model/license](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface), [AWS liveness](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness.html), [FPT liveness](https://docs.fpt.ai/docs/en/vision/api/liveness/), [Sumsub Flutter plugin](https://docs.sumsub.com/docs/flutter-plugin). These establish documented capabilities, not proven Nene integration. No models or new SDKs were installed.

Google ML Kit face detection finds faces/features but does not recognize people; it can support capture framing, not replace matching. Device unlock is likewise separate from Nene's identity association and transaction authorization. [Google's capability statement](https://developers.google.com/ml-kit/vision/face-detection).

## Retained pricing notes, not a purchasing decision

The following public figures were checked on 2026-10-27. Recheck account access, region, minimum purchase, taxes and final service terms before any paid implementation. Costs for liveness bundles are not the cost of the newly simplified reference-only foundation.

| Service | Published basis and limits of the estimate |
| --- | --- |
| AWS | Pricing examples show Group 1 image analysis at USD 0.001/image and US East (N. Virginia) liveness at USD 0.015/check. CompareFaces is Group 1 and counts one source image per call. Illustratively, 100 comparisons are USD 0.10; adding 100 liveness checks makes USD 1.60. Extra calls, retries, tax and other infrastructure charges are excluded. No region or service has been selected. |
| FPT.AI liveness | Public table lists VND 1,000/request below 10,000 requests/month, with optional reference image: 100 such requests would be VND 100,000 before unverified extras. This is a liveness price, not a verified standalone FaceMatch quote. Confirm access, trial allowance, minimum top-up and tax. |
| Sumsub | Basic lists USD 1.35/verification with USD 149 minimum monthly commitment; face authentication is listed separately. A 14-day/50-check trial is advertised. Confirm current feature entitlement and repeated-check pricing; a trial is not established project-long access. |

Sources: [AWS pricing](https://aws.amazon.com/rekognition/pricing/) and [billing-unit FAQ](https://aws.amazon.com/rekognition/faqs/); [FPT liveness pricing](https://docs.fpt.ai/docs/en/vision/documentation/liveness-pricing/) and [trial entry points](https://fpt.ai/try-for-free/); [Sumsub pricing](https://sumsub.com/pricing/). FPT.AI API pricing is distinct from separately quoted FPT-eID packages. Sumsub's [action guidance](https://docs.sumsub.com/docs/applicant-actions-ios) deprecates its old Face authentication action type; reconfirm the supported repeat-check flow if selecting it. No quote, account eligibility or charge was tested.

## How to make the eventual decision small

1. Review the implemented [reference foundation](REFERENCE_FLOW.md) in the web demo. Its notice, seven-day access expiry, maintenance-driven deletion and officer confirmation are local project defaults; no liveness dependency is needed to record an accepted reference.
2. Define a small comparison contract: accepted reference plus operation capture in; actual match/non-match/unavailable result out, interpreted by NestJS. Evaluate the least burdensome implementation that meets this contract and the lecturer's eKYC expectations. Do not infer a pass from upload success, a face-detection box or an officer click.
3. Prove positive/negative comparisons, failure handling, ownership, expired/reused/wrong-operation rejection and reference-version invalidation. Choose thresholds/attempt limits explicitly; model defaults are not an identity policy.
4. Record spoofing limitations. Requesting a new camera image and binding a result to an operation does not prove live presence or defeat image injection/replay. If stronger assurance is required, choose the additional mechanism deliberately and revise the scope/design then.

AWS-specific Compose/platform-channel work, credentials, capture sessions and SDK theming are contingent future evaluation topics only. The earlier read-only check found Nene's Android API 24 minimum matched AWS's documented minimum, but compilation/capture compatibility was never tested; this creates no commitment to build the bridge. [AWS Android guide](https://ui.docs.amplify.aws/android/connected-components/liveness), [Flutter platform channels](https://docs.flutter.dev/platform-integration/platform-channels).

Browser preview can exercise UI/status fixtures; camera behavior needs separate platform testing. Browser camera access requires a secure context, so ordinary HTTP LAN preview is not a guaranteed camera-testing path. A physical Android test remains appropriate for the eventual Android capture implementation, regardless of provider. [Browser camera contract](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia).

Evidence limits: this is retained public-source research plus a user-directed documentation change. No provider, native bridge, camera behavior, commercial access, biometric accuracy or end-to-end identity check has been verified. No new account, charge, real-person test or application change occurred. The shared policy folder remained unavailable; the source PDF/rubric and local-only launcher work are unchanged.
