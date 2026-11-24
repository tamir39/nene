import 'dart:js_interop';

@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(JSString url);

Future<void> cleanCapture(String path) async {
  if (path.startsWith('blob:')) _revokeObjectUrl(path.toJS);
}
