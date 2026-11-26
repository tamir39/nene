// Renders review screenshots of the face step before a large transfer with
// the bundled Be Vietnam Pro font. Skipped in ordinary runs; generate with:
//   flutter test test/ui_capture_face_test.dart --dart-define=CAPTURE_UI=true
// Images are written to the ignored ../.tmp/ui-review/ folder.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'confirmation_screen_test.dart' as fixture show tap;
import 'face_verification_test.dart'
    show Backend, FakeLiveness, captureKey, matched, mount, review;

const _capture = bool.fromEnvironment('CAPTURE_UI');

Future<void> _fonts(WidgetTester tester) async {
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
  Future<ByteData> bytes(String path) =>
      File(path).readAsBytes().then(ByteData.sublistView);
  await tester.runAsync(() async {
    final family = FontLoader('BeVietnamPro');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      family.addFont(bytes('assets/fonts/BeVietnamPro-$weight.ttf'));
    }
    await family.load();
    await (FontLoader('MaterialIcons')..addFont(
          bytes(
            '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ))
        .load();
  });
}

Future<void> _shoot(
  WidgetTester tester,
  String name, {
  bool settle = true,
}) async {
  if (settle) await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../.tmp/ui-review/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
  expect(tester.takeException(), isNull);
}

/// Scrolls the face step (or the code card) into view before a capture.
Future<void> _show(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('face step on a device', (tester) async {
    final slow = Completer<http.Response>();
    final backend = Backend(
      face: [
        () => http.Response(
          jsonEncode({'matched': false, 'reason': 'not_matched'}),
          422,
        ),
        () => slow.future,
      ],
    );
    await _fonts(tester);
    await mount(tester, backend, height: 844);
    await review(tester);
    await _show(tester, 'Take photo 1');
    await _shoot(tester, 'face-1-photo-one');
    await fixture.tap(tester, 'Take photo 1');
    await _show(tester, 'Take photo 2');
    await _shoot(tester, 'face-2-photo-two');
    await fixture.tap(tester, 'Take photo 2');
    await _show(tester, 'Try the face check again');
    await _shoot(tester, 'face-3-not-matched');
    await fixture.tap(tester, 'Try the face check again');
    await tester.tap(find.text('Take photo 2'));
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.ensureVisible(find.textContaining('Comparing with'));
    await tester.pump(const Duration(milliseconds: 100));
    await _shoot(tester, 'face-4-comparing', settle: false);
    slow.complete(matched());
    await tester.pumpAndSettle();
    await _show(tester, 'Authenticator code');
    await _shoot(tester, 'face-5-matched-code');
  }, skip: !_capture);

  testWidgets('face step on web', (tester) async {
    await _fonts(tester);
    await mount(
      tester,
      Backend(),
      liveness: FakeLiveness(available: false),
      height: 844,
    );
    await review(tester);
    await _show(tester, 'Take or choose a photo');
    await _shoot(tester, 'face-6-web');
  }, skip: !_capture);

  testWidgets('face step at 320 px and 2x text', (tester) async {
    await _fonts(tester);
    await mount(tester, Backend(), width: 320, textScale: 2, height: 1400);
    await review(tester);
    await _show(tester, 'Face check required');
    await _shoot(tester, 'face-7-320-2x');
    await tester.pumpWidget(const SizedBox());
    await mount(tester, Backend(), width: 320, textScale: 2, height: 1400);
    expect(find.textContaining('needs a face check'), findsOneWidget);
    await _show(tester, 'Review confirmation');
    await _shoot(tester, 'face-8-amount-hint-320-2x');
  }, skip: !_capture);
}
