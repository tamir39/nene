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

/// Which liveness photo is being checked before a high-value transfer.
enum LivenessPose {
  /// Looking straight at the camera with both eyes open.
  straight,

  /// Head turned clearly to the left or right.
  turned,
}

/// On-device result for one liveness photo.
///
/// These are simple pose checks on still photos. They raise the effort of
/// using a printed photo but are not certified liveness or anti-spoofing; the
/// server's comparison with the accepted reference photo is the control.
enum LivenessResult {
  passed,
  noFace,
  multipleFaces,
  eyesClosed,
  notStraight,
  notTurned,

  /// The detector could not measure this photo.
  failed,
}

/// The measurements ML Kit reports for one detected face.
class FaceMeasurement {
  const FaceMeasurement({this.yaw, this.leftEyeOpen, this.rightEyeOpen});

  /// Head rotation around the vertical axis in degrees (left/right turn).
  final double? yaw;
  final double? leftEyeOpen;
  final double? rightEyeOpen;
}

/// Both eyes must be more likely open than this in the straight photo.
const minimumEyeOpenProbability = 0.6;

/// The straight photo must face the camera within this many degrees.
const maximumStraightYaw = 12.0;

/// The turned photo must be rotated by more than this many degrees.
const minimumTurnedYaw = 20.0;

LivenessResult classifyLiveness(
  LivenessPose pose,
  List<FaceMeasurement> faces,
) {
  if (faces.isEmpty) return LivenessResult.noFace;
  if (faces.length > 1) return LivenessResult.multipleFaces;
  final face = faces.single;
  final yaw = face.yaw;
  if (yaw == null) return LivenessResult.failed;
  switch (pose) {
    case LivenessPose.straight:
      final left = face.leftEyeOpen, right = face.rightEyeOpen;
      if (left == null || right == null) return LivenessResult.failed;
      if (left <= minimumEyeOpenProbability ||
          right <= minimumEyeOpenProbability) {
        return LivenessResult.eyesClosed;
      }
      return yaw.abs() < maximumStraightYaw
          ? LivenessResult.passed
          : LivenessResult.notStraight;
    case LivenessPose.turned:
      return yaw.abs() > minimumTurnedYaw
          ? LivenessResult.passed
          : LivenessResult.notTurned;
  }
}

/// Checks liveness photos on the device. Implementations never throw;
/// detector problems are reported as [LivenessResult.failed].
abstract interface class LivenessCheck {
  /// False on web and desktop previews, where no detector runs.
  bool get available;
  Future<LivenessResult> check(LivenessPose pose, Uint8List bytes);
}

class UnavailableLivenessCheck implements LivenessCheck {
  const UnavailableLivenessCheck();

  @override
  bool get available => false;

  @override
  Future<LivenessResult> check(LivenessPose pose, Uint8List bytes) async =>
      LivenessResult.failed;
}

/// ML Kit pose checks on Android/iOS; [UnavailableLivenessCheck] on web and
/// desktop.
LivenessCheck createDeviceLivenessCheck() => device.createLivenessCheck();
