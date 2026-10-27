import 'dart:io';

/// Only called with a temporary file returned by the camera plugin, never a
/// gallery selection, arbitrary input path or user-owned original.
Future<void> cleanCapture(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}
