import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'reference_photo_cleanup_stub.dart'
    if (dart.library.io) 'reference_photo_cleanup_io.dart'
    if (dart.library.js_interop) 'reference_photo_cleanup_web.dart';

class ReferencePhoto {
  const ReferencePhoto(this.bytes, this.contentType);
  final Uint8List bytes;
  final String contentType;
}

class PhotoCaptureException implements Exception {
  const PhotoCaptureException(this.message);
  final String message;
}

abstract interface class ReferencePhotoSource {
  Future<ReferencePhoto?> capture();
}

class DeviceReferencePhotoSource implements ReferencePhotoSource {
  DeviceReferencePhotoSource({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;

  /// A process restart drops the session. Never restore a previous photo into
  /// another user's enrollment; discard any Android camera result instead.
  Future<void> discardLostCapture() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final result = await _picker.retrieveLostData();
    for (final file in result.files ?? <XFile>[]) {
      await cleanCapture(file.path);
    }
  }

  @override
  Future<ReferencePhoto?> capture() async {
    XFile? file;
    try {
      // Web uses a browser-managed file picker. Some mobile browsers offer a
      // camera; the UI does not promise webcam capture or proof of live presence.
      file = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 88,
        requestFullMetadata: false,
      );
      if (file == null) return null;
      if (await file.length() > 10 * 1024 * 1024) {
        throw const PhotoCaptureException(
          'Choose a JPEG or PNG photo smaller than 10 MiB.',
        );
      }
      final bytes = await file.readAsBytes();
      final type = photoContentType(bytes);
      await validatePhotoDimensions(bytes);
      return ReferencePhoto(bytes, type);
    } on PlatformException {
      throw const PhotoCaptureException(
        'The camera is unavailable or permission was denied. Check camera access in device settings, or ask your officer for assistance.',
      );
    } on PhotoCaptureException {
      rethrow;
    } catch (_) {
      throw const PhotoCaptureException(
        'The photo could not be opened. Try a JPEG or PNG photo, or ask your officer for assistance.',
      );
    } finally {
      if (file != null) {
        try {
          await cleanCapture(file.path);
        } catch (_) {
          throw const PhotoCaptureException(
            'The temporary capture could not be cleared. Close the app and clear its temporary data before trying again.',
          );
        }
      }
    }
  }
}

String photoContentType(Uint8List bytes) {
  if (bytes.length < 8 || bytes.length > 10 * 1024 * 1024) {
    throw const PhotoCaptureException(
      'Use a JPEG or PNG photo smaller than 10 MiB.',
    );
  }
  if (bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  const png = [137, 80, 78, 71, 13, 10, 26, 10];
  if (listEquals(bytes.sublist(0, 8), png)) return 'image/png';
  throw const PhotoCaptureException(
    'Use a JPEG or PNG photo. Other file types are not accepted.',
  );
}

Future<void> validatePhotoDimensions(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > 4096 || descriptor.height > 4096) {
      throw const PhotoCaptureException(
        'Use a photo no larger than 4096 × 4096 pixels.',
      );
    }
    codec = await descriptor.instantiateCodec(targetWidth: 512);
    final frame = await codec.getNextFrame();
    frame.image.dispose();
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
