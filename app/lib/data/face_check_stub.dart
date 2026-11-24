import 'face_check.dart';

/// Web builds never import ML Kit, which needs dart:io and a mobile platform.
FaceCheck createFaceCheck() => const UnavailableFaceCheck();
