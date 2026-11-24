import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'face_check_stub.dart'
    if (dart.library.io) 'face_check_mlkit.dart'
    as device;

/// Outcome of the on-device face check for one reference photo.
///
/// This is face detection only: it says whether the photo shows exactly one
/// large-enough face. It does not identify or compare anyone, prove live
/// presence or complete eKYC. The server accepts any valid image, so an
/// officer's review remains the control.
enum FaceCheckResult {
  oneFace,
  noFace,
  multipleFaces,
  faceTooSmall,

  /// No detector on this platform (web and desktop previews).
  unavailable,

  /// The detector could not process this photo.
  failed;

  /// Detector gaps never lock enrollment: the officer still reviews the photo.
  bool get allowsUpload => switch (this) {
    oneFace || unavailable || failed => true,
    noFace || multipleFaces || faceTooSmall => false,
  };
}

/// Checks an encoded JPEG/PNG photo. Implementations never throw; detector
/// problems are reported as [FaceCheckResult.failed].
abstract interface class FaceCheck {
  Future<FaceCheckResult> check(Uint8List bytes);
}

class UnavailableFaceCheck implements FaceCheck {
  const UnavailableFaceCheck();

  @override
  Future<FaceCheckResult> check(Uint8List bytes) async =>
      FaceCheckResult.unavailable;
}

/// ML Kit's bundled detector on Android/iOS; [UnavailableFaceCheck] on web
/// and desktop, where ML Kit does not run.
FaceCheck createDeviceFaceCheck() => device.createFaceCheck();

/// A face's smaller box side must cover this share of the photo's shorter
/// side, so the officer can see the face clearly.
const minimumFaceShare = 0.2;

FaceCheckResult classifyFaces(List<Rect> faces, Size image) {
  if (faces.isEmpty) return FaceCheckResult.noFace;
  if (faces.length > 1) return FaceCheckResult.multipleFaces;
  return faces.single.shortestSide >= minimumFaceShare * image.shortestSide
      ? FaceCheckResult.oneFace
      : FaceCheckResult.faceTooSmall;
}
