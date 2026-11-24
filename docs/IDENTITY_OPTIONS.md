# Face comparison options and recommendation

**Later user decision, 2026-11-05:** leave face comparison itself and all providers undecided for now. The research recommendation below is retained for reference, not the next implementation task. See the [scope/status audit](SCOPE_STATUS_AUDIT.md). No matching experiment or AWS setup is scheduled; eKYC remains unresolved and high-value posting stays blocked.

Research update: **2026-11-05**, requested after the local deposits/withdrawals slice. **Recommend evaluating AWS Rekognition CompareFaces first; no provider is selected or integration authorized by this recommendation.** AWS remains undecided. This replaces the unranked background comparison of 2026-10-27, without reversing the decision to keep the identity flow small.

## PDF scope and existing foundation

The [PDF](../FinalProject_2026_2027.pdf), p. 2 Business 2 (BR-03/BR-04), requires eKYC, officer biometric assistance and transaction 2FA. Face-photo enrollment and later high-value verification are its example. It specifies no vendor, algorithm, liveness SDK or document-scanning product. See [REQUIREMENTS.md](../REQUIREMENTS.md) for the distinction between requirements and our chosen face-based design.

Nene already has [private reference capture and officer acceptance](REFERENCE_FLOW.md), Supabase Auth and transaction-bound TOTP. The missing step is an actual server-side comparison of the accepted reference with a newly requested operation capture. Reference acceptance, face detection and a successful upload do not perform this comparison. A comparison alone also does not establish live presence, government identity or completion of BR-03; lecturer expectations and demonstrable end-to-end behavior still matter.

Keep Flutter, one NestJS API and Supabase PostgreSQL/Auth/private Storage. The user accepts a small pay-as-you-go cost, but this research does not authorize provider accounts, charges or photo uploads. High-value local operations remain blocked at **5,000,000 VND or more**; that threshold is our demo policy, not PDF wording.

## Simplest credible options

Relative effort below is an engineering judgment for Nene's existing TypeScript backend, not a measured integration or accuracy benchmark.

| Option | Documented capability | Effort and trade-off for Nene | Recommendation |
| --- | --- | --- | --- |
| **AWS Rekognition CompareFaces** | JPEG/PNG comparison using image bytes, with similarity and quality information. | Small backend adapter, but needs AWS account/IAM setup, network access, per-call billing and external photo processing. No model runtime to maintain. | **First candidate to evaluate:** clear API and public usage pricing fit a bounded project experiment. |
| **FPT.AI FaceMatch** | API-key HTTP request with two JPEG files; returns similarity and a match flag based on an 80% threshold. Images must be at most 5 MB, approximately 640x480 minimum, with a sufficiently large face. | Potentially equally simple request integration. Standalone FaceMatch pricing, account access, minimum purchase, retention terms and multiple-face handling were not established by the reviewed contract. | Alternative if access and terms are confirmed. Do not use FPT liveness prices as a FaceMatch quote. |
| **OpenCV YuNet + SFace** | Pretrained ONNX detection and recognition models; detect, align, extract features and compare them locally. Official examples use C++/Python. | No external comparison fee or photo upload when run locally, but requires runtime/model packaging, integration with NestJS, resource management and threshold evaluation. | Local-only fallback if external processing is unacceptable. More implementation work for this stack. |

Sources: [AWS API](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CompareFaces.html), [FPT API](https://docs.fpt.ai/docs/en/vision/api/face-match/), [OpenCV tutorial](https://docs.opencv.org/4.13.0/d0/dd4/tutorial_dnn_face.html). FPT's response body must be checked for error codes even when its message says success. OpenCV benchmark thresholds vary by dataset; they are not established Nene accuracy. Pin any selected runtime/model versions and review their individual licenses before distribution: [SFace model files](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface).

## Why recommend the AWS comparison API

NestJS can fetch the authorized private reference from Supabase and send image bytes with the operation capture. S3, Lambda, face collections, a native Flutter bridge and an AWS liveness SDK are unnecessary for that request. Supabase remains our storage and authentication provider. This is a narrow external comparison adapter, not a move to an AWS architecture. [CompareFaces contract](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CompareFaces.html).

The trade is less model-integration work in exchange for a provider dependency, account configuration and external image handling. FPT could become the simpler choice if its commercial/access details are resolved; there is no evidence here that AWS is more accurate for Nene's users. Keep a small backend comparison interface so provider changes do not change banking authorization or Flutter screens; do not build multiple implementations now.

AWS's pricing examples show **USD 0.001 per image** in the first volume tier for Groups 1 and 2. CompareFaces is Group 1 and bills one source image per comparison; DetectFaces is Group 2. Illustratively, **100 comparisons cost USD 0.10**, or **USD 0.30 with two additional DetectFaces requests per comparison**. These are arithmetic estimates from public examples, not a region/account quote; exclude retries, taxes, hosting and data transfer. Confirm the chosen region and account pricing before use and do not assume free-tier eligibility. [Pricing](https://aws.amazon.com/rekognition/pricing/), [billing units](https://aws.amazon.com/rekognition/faqs/).

Privacy is a real trade-off: AWS says inputs may be stored and used to maintain its service, and used for service improvement unless opted out through AWS Organizations. Its FAQ describes requesting input deletion through Support. The API being stateless does **not** mean input photos are never retained. Before uploading agreed test images, settle region, the relevant opt-out settings, notice/consent and provider retention/deletion handling. Nene's seven-day Supabase expiry/deletion policy does not automatically delete a provider's copy. [AWS data-privacy FAQ](https://aws.amazon.com/rekognition/faqs/).

## Smallest next experiment, after provider selection

1. **Comparison only, with posting disabled.** Exercise the NestJS adapter with agreed test images. Return match, non-match, invalid capture or unavailable; do not turn provider errors into a pass. Credentials remain backend-only. No photo, credential or detailed biometric response logging.
2. **Validate both images.** Enforce actual format, bounded dimensions and decoded size; normalize or reject oversized files. AWS raw-byte requests allow at most 5 MB, smaller than Nene's current reference upload ceiling. Require exactly one face in each image, using DetectFaces or an equivalent validated check: CompareFaces otherwise selects the largest source face. Reject no-face, multiple-face and unusable-quality captures. [AWS limits](https://docs.aws.amazon.com/rekognition/latest/dg/limits.html), [comparison behavior](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CompareFaces.html).
3. **Evaluate a threshold explicitly.** Test same-person/different-person pairs and lighting/pose variations; measure false accepts/rejects on the agreed small test set. Neither AWS's default 80 nor FPT's default match flag is a banking acceptance policy. Similarity is not a probability of identity. Record a proposed threshold and attempt limit with evidence; a small trial cannot establish population-wide accuracy. AWS recommends human review for decisions affecting access; preserve officer assistance for failures without adding a bypass. [AWS guidance](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CompareFaces.html).
4. **Bind the eventual result to one operation.** On integration, bind customer/session, accepted reference revision, operation kind, account/destination, amount/currency, operation revision and expiry. Reject reused, expired or wrong-operation results and reference changes. Require the existing separate TOTP and recheck current permissions/balances at atomic posting. Changing the reviewed operation invalidates its identity result.
5. **Prove failure behavior before enabling any high-value path.** Cover ownership, replay, duplicate/concurrent requests, timeout, rate limit and provider outage. Exercise Edge capture permission denial and the eventual Android capture separately. Keep high-value gates closed until the integrated checks and documented policy pass.

This is a proposed experiment and acceptance plan, not implemented behavior. Photo comparison does not defeat printed-photo/screen replay or prove capture freshness; binding protects the operation, not the camera. The project report must state that limit. Liveness, OCR/NFC, full KYC suites and custom model training are outside this minimum step unless a concrete requirement justifies them.

Browser camera access needs a secure context; PC localhost can be usable, while ordinary HTTP LAN preview is not a dependable phone-camera path. Continue using the user-started Edge demo; do not launch an emulator as part of this research. [Camera API contract](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia).

## Evidence and decision status

Checked the PDF's complete security-requirements page, current roadmap and official sources above on 2026-11-05. No provider call, account, charge, image upload, model installation or application test occurred. Accuracy, latency, commercial access and end-to-end capture remain unverified. The shared policy folder `D:\Data\Downloads\Policies` was still unavailable; no policy compliance is claimed. Original assessment files and local-only launcher changes remain untouched.

**Deferred decision:** decide whether to retain the face-comparison approach before selecting a provider or experiment. The research recommendation is not an approved next step. Selection alone must not silently provision resources or incur costs. Continue the remaining PDF feature groups in [ROADMAP.md](../ROADMAP.md).
