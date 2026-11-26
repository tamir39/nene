import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'face_check.dart';

FaceCheck createFaceCheck() =>
    !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)
    ? const MlKitFaceCheck()
    : const UnavailableFaceCheck();

LivenessCheck createLivenessCheck() =>
    !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)
    ? const MlKitLivenessCheck()
    : const UnavailableLivenessCheck();

/// Google ML Kit face detection with the model bundled in the app: the photo
/// is processed on the device, nothing is downloaded and no account is used.
class MlKitFaceCheck implements FaceCheck {
  const MlKitFaceCheck();

  @override
  Future<FaceCheckResult> check(Uint8List bytes) async {
    final detector = FaceDetector(
      options: FaceDetectorOptions(performanceMode: FaceDetectorMode.accurate),
    );
    try {
      // Decode with Flutter so the detector sees the same upright pixels as
      // the preview, without writing the photo to a temporary file.
      final (pixels, width, height) = await _rgba(bytes);
      final faces = await detector.processImage(
        InputImage.fromBitmap(bitmap: pixels, width: width, height: height),
      );
      return classifyFaces([
        for (final face in faces) face.boundingBox,
      ], ui.Size(width.toDouble(), height.toDouble()));
    } catch (_) {
      return FaceCheckResult.failed;
    } finally {
      try {
        await detector.close();
      } catch (_) {
        // Nothing to release if the detector never started.
      }
    }
  }
}

/// ML Kit head-pose and eye-open classification for liveness photos, with
/// the same bundled on-device model as [MlKitFaceCheck].
class MlKitLivenessCheck implements LivenessCheck {
  const MlKitLivenessCheck();

  @override
  bool get available => true;

  @override
  Future<LivenessResult> check(LivenessPose pose, Uint8List bytes) async {
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableClassification: true,
      ),
    );
    try {
      final (pixels, width, height) = await _rgba(bytes);
      final faces = await detector.processImage(
        InputImage.fromBitmap(bitmap: pixels, width: width, height: height),
      );
      return classifyLiveness(pose, [
        for (final face in faces)
          FaceMeasurement(
            yaw: face.headEulerAngleY,
            leftEyeOpen: face.leftEyeOpenProbability,
            rightEyeOpen: face.rightEyeOpenProbability,
          ),
      ]);
    } catch (_) {
      return LivenessResult.failed;
    } finally {
      try {
        await detector.close();
      } catch (_) {
        // Nothing to release if the detector never started.
      }
    }
  }
}

Future<(Uint8List, int, int)> _rgba(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    codec = await descriptor.instantiateCodec();
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('Photo pixels unavailable');
    return (
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      image.width,
      image.height,
    );
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
