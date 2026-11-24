// Renders review screenshots of the assistant, offices and identity-reference
// screens with the bundled Be Vietnam Pro font. Skipped in ordinary runs;
// generate with:
//   flutter test test/ui_capture_explore_test.dart --dart-define=CAPTURE_UI=true
// Images are written to the ignored ../.tmp/ui-review/ folder (explore-*).
// Map tiles are drawn locally; no tile service is contacted.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:nene_app/assistant_controller.dart';
import 'package:nene_app/data/branch_location.dart';
import 'package:nene_app/data/identity_repository.dart';
import 'package:nene_app/session_controller.dart';
import 'package:nene_app/ui/assistant_screen.dart';
import 'package:nene_app/ui/branch_map_screen.dart';
import 'package:nene_app/ui/identity_reference_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';

import 'assistant_test.dart' as assistant;
import 'branch_map_test.dart' as branch;
import 'identity_test_doubles.dart';
import 'test_doubles.dart';

const _capture = bool.fromEnvironment('CAPTURE_UI');
const _key = ValueKey('explore-capture');

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

void _size(WidgetTester tester, double height) {
  tester.view.physicalSize = Size(390, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Mirrors the workspace chrome: logo app bar and, for tabs, the bottom bar.
Widget _frame(Widget body, {int? tab, double scale = 1}) => RepaintBoundary(
  key: _key,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: neneTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: tab == null
            ? IconButton(
                tooltip: 'Back',
                onPressed: () {},
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        title: const NeneLogo(size: 30),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: () {},
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: tab == null
          ? null
          : NavigationBar(
              selectedIndex: tab,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: 'Assistant',
                ),
                NavigationDestination(
                  icon: Icon(Icons.map_outlined),
                  selectedIcon: Icon(Icons.map),
                  label: 'Offices',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  label: 'Profile',
                ),
              ],
            ),
    ),
  ),
);

Future<void> _shoot(
  WidgetTester tester,
  String name, {
  bool settle = true,
}) async {
  for (final element in find.byType(Image).evaluate()) {
    final image = (element.widget as Image).image;
    if (image is MemoryImage) {
      await tester.runAsync(() => precacheImage(image, element));
    }
  }
  // Map tiles decode asynchronously; give them real time before painting.
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_key));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../.tmp/ui-review/explore-$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
  expect(tester.takeException(), isNull);
}

// ---------------------------------------------------------------- assistant

Future<AssistantController> _chat(
  Future<http.Response> Function(http.Request) handler,
) async {
  final session = await assistant.owner();
  addTearDown(session.dispose);
  final chat = AssistantController(
    session: session,
    api: assistant.api(handler),
  );
  addTearDown(chat.dispose);
  return chat;
}

http.Response _answer(http.Request request) {
  final text = request.body;
  if (text.contains('electricity')) {
    return assistant.reply(
      text:
          'Open the labelled electricity and water bill demos. Sandbox '
          'checkout requires configuration, review and your authenticator. A '
          'sandbox payment does not settle a real bill. No payment has been '
          'created or sent.',
      actions: [
        {'type': 'bills'},
      ],
    );
  }
  if (text.contains('Transfer')) {
    return assistant.reply(
      text:
          'I can open the same-bank demo transfer screen. Choose an eligible '
          'account and enter the details there. I have not created or sent a '
          'transaction.',
      actions: [
        {'type': 'transfer'},
        {'type': 'interbank_transfer'},
      ],
    );
  }
  return assistant.reply(
    text:
        'Open your transaction history for 2026-11, then choose one of your '
        'accounts. Only posted transactions for that month will be shown. '
        'Month boundaries use UTC+07.',
    actions: [
      {'type': 'history', 'month': '2026-11'},
    ],
  );
}

// ------------------------------------------------------------------ offices

/// A locally drawn, map-like tile so captures show a realistic card without
/// contacting a tile service.
class _DrawnTiles extends TileProvider {
  _DrawnTiles(this.bytes);
  final Uint8List bytes;
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(bytes);
}

Future<Uint8List> _tile(WidgetTester tester) async {
  late Uint8List bytes;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 256, 256),
      Paint()..color = const Color(0xFFF1F0EA),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(150, 24, 80, 70),
        const Radius.circular(10),
      ),
      Paint()..color = const Color(0xFFDDEBDD),
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 196, 256, 30),
      Paint()..color = const Color(0xFFD6E6EE),
    );
    final road = Paint()
      ..color = Colors.white
      ..strokeWidth = 9;
    final lane = Paint()
      ..color = Colors.white
      ..strokeWidth = 4;
    canvas
      ..drawLine(const Offset(0, 120), const Offset(256, 120), road)
      ..drawLine(const Offset(100, 0), const Offset(100, 256), road)
      ..drawLine(const Offset(0, 54), const Offset(256, 54), lane)
      ..drawLine(const Offset(200, 0), const Offset(200, 256), lane)
      ..drawLine(const Offset(30, 0), const Offset(30, 190), lane);
    final image = await recorder.endRecording().toImage(256, 256);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    bytes = data!.buffer.asUint8List();
    image.dispose();
  });
  return bytes;
}

Future<void> _offices(
  WidgetTester tester, {
  required Future<http.Response> Function(http.Request) handler,
  branch.FakeLocation? location,
  double height = 844,
  double scale = 1,
}) async {
  _size(tester, height);
  await _fonts(tester);
  final tiles = _DrawnTiles(await _tile(tester));
  final session = await branch.session();
  addTearDown(session.dispose);
  await tester.pumpWidget(
    _frame(
      BranchMapScreen(
        session: session,
        api: branch.api(handler),
        location: location,
        tileProvider: tiles,
      ),
      tab: 2,
      scale: scale,
    ),
  );
  await tester.pumpAndSettle();
}

Future<http.Response> _catalog(http.Request request) async =>
    request.method == 'POST'
    ? branch.json(branch.route)
    : branch.json(branch.catalog);

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

/// Scrolls the screen's single vertical scroll view so [text] is in view.
Future<void> _reveal(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.pumpAndSettle();
}

// ----------------------------------------------------------------- identity

Future<FakeIdentity> _identity(
  WidgetTester tester, {
  bool officer = false,
  String status = 'not_started',
  int version = 1,
  bool expired = false,
  double height = 844,
  double scale = 1,
}) async {
  _size(tester, height);
  await _fonts(tester);
  final auth = FakeAuth();
  final profiles = FakeProfiles();
  if (officer) profiles.fetch = (_) async => officerProfile;
  final session = SessionController(auth: auth, profiles: profiles);
  addTearDown(() async {
    session.dispose();
    await auth.events.close();
  });
  final repository = FakeIdentity()
    ..value = IdentitySummary.fromJson(
      identityJson(
        status: status,
        version: version,
        expired: expired,
        customerId: officer ? 'customer-id' : 'user-id',
      ),
    );
  await session.signIn('demo@example.test', 'synthetic-password');
  await tester.pumpWidget(
    _frame(
      IdentityReferenceScreen(
        session: session,
        repository: repository,
        photos: FakePhotos(),
        customerId: officer ? 'customer-id' : null,
      ),
      scale: scale,
    ),
  );
  await _settlePhoto(tester);
  return repository;
}

Future<void> _settlePhoto(WidgetTester tester) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
  await tester.pumpAndSettle();
}

Future<void> _identityTap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.pump();
  await tester.tap(find.text(text));
  await _settlePhoto(tester);
}

void main() {
  group('assistant', () {
    testWidgets('welcome', (tester) async {
      if (!_capture) return;
      _size(tester, 844);
      await _fonts(tester);
      final chat = await _chat((r) async => _answer(r));
      await tester.pumpWidget(
        _frame(AssistantScreen(controller: chat, onAction: (_) {}), tab: 1),
      );
      await _shoot(tester, 'assistant-welcome');
    });

    testWidgets('welcome at 200% text', (tester) async {
      if (!_capture) return;
      _size(tester, 844);
      await _fonts(tester);
      final chat = await _chat((r) async => _answer(r));
      await tester.pumpWidget(
        _frame(
          AssistantScreen(controller: chat, onAction: (_) {}),
          tab: 1,
          scale: 2,
        ),
      );
      await _shoot(tester, 'assistant-welcome-text200');
    });

    testWidgets('conversation', (tester) async {
      if (!_capture) return;
      _size(tester, 844);
      await _fonts(tester);
      final chat = await _chat((r) async => _answer(r));
      await tester.pumpWidget(
        _frame(AssistantScreen(controller: chat, onAction: (_) {}), tab: 1),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transactions this month'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Pay my electricity bill');
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      await _shoot(tester, 'assistant-chat');
    });

    testWidgets('conversation, full height', (tester) async {
      if (!_capture) return;
      _size(tester, 1400);
      await _fonts(tester);
      final chat = await _chat((r) async => _answer(r));
      await chat.send('Transactions this month');
      await chat.send('Transfer money');
      await tester.pumpWidget(
        _frame(AssistantScreen(controller: chat, onAction: (_) {}), tab: 1),
      );
      await _shoot(tester, 'assistant-chat-full');
    });

    testWidgets('typing', (tester) async {
      if (!_capture) return;
      _size(tester, 844);
      await _fonts(tester);
      final pending = Completer<http.Response>();
      final chat = await _chat((_) => pending.future);
      await tester.pumpWidget(
        _frame(AssistantScreen(controller: chat, onAction: (_) {}), tab: 1),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Top up my phone'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Top up my phone'));
      await tester.pump();
      await _shoot(tester, 'assistant-typing', settle: false);
      pending.complete(assistant.reply());
      await tester.pumpAndSettle();
    });

    testWidgets('error and retry', (tester) async {
      if (!_capture) return;
      _size(tester, 844);
      await _fonts(tester);
      final chat = await _chat((_) async => http.Response('', 503));
      await tester.pumpWidget(
        _frame(AssistantScreen(controller: chat, onAction: (_) {}), tab: 1),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transfer money'));
      await tester.pumpAndSettle();
      await _shoot(tester, 'assistant-error');
    });
  });

  group('offices', () {
    testWidgets('initial', (tester) async {
      if (!_capture) return;
      await _offices(tester, handler: _catalog);
      await _shoot(tester, 'offices');
    });

    testWidgets('initial, full height', (tester) async {
      if (!_capture) return;
      await _offices(tester, handler: _catalog, height: 1500);
      await _shoot(tester, 'offices-full');
    });

    testWidgets('demo point and walking route', (tester) async {
      if (!_capture) return;
      await _offices(tester, handler: _catalog, height: 1700);
      await _tapText(tester, 'Use TDTU demo starting point');
      await _tapText(tester, 'Walking route to nearest');
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, 2000),
      );
      await _shoot(tester, 'offices-route-full');
    });

    testWidgets('demo point and walking route, phone height', (tester) async {
      if (!_capture) return;
      await _offices(tester, handler: _catalog);
      await _tapText(tester, 'Use TDTU demo starting point');
      await _tapText(tester, 'Walking route to nearest');
      await _shoot(tester, 'offices-route');
    });

    testWidgets('location permission blocked', (tester) async {
      if (!_capture) return;
      await _offices(
        tester,
        handler: _catalog,
        location: branch.FakeLocation()
          ..read = () async => throw const BranchLocationException(
            'Location permission is blocked. Allow it in browser or device '
            'settings, or use the demo starting point.',
          ),
      );
      await _tapText(tester, 'Use my location');
      await _reveal(tester, 'Use TDTU demo starting point');
      await _shoot(tester, 'offices-denied');
    });

    testWidgets('no office within 5 km', (tester) async {
      if (!_capture) return;
      await _offices(
        tester,
        handler: _catalog,
        location: branch.FakeLocation()..read = () async => const LatLng(0, 0),
      );
      await _tapText(tester, 'Use my location');
      await _shoot(tester, 'offices-none');
    });

    testWidgets('catalog unavailable', (tester) async {
      if (!_capture) return;
      await _offices(tester, handler: (_) async => branch.json({}, 503));
      await _shoot(tester, 'offices-error');
    });

    testWidgets('route at 200% text', (tester) async {
      if (!_capture) return;
      await _offices(tester, handler: _catalog, height: 844, scale: 2);
      await _tapText(tester, 'Use TDTU demo starting point');
      await _tapText(tester, 'Walking route to nearest');
      await _shoot(tester, 'offices-route-text200');
    });
  });

  group('identity', () {
    testWidgets('customer not started', (tester) async {
      if (!_capture) return;
      await _identity(tester, height: 1100);
      await _shoot(tester, 'identity-start');
    });

    testWidgets('customer photo preview', (tester) async {
      if (!_capture) return;
      await _identity(tester, height: 1300);
      await _identityTap(
        tester,
        'I understand this notice and agree to submit an agreed test image.',
      );
      await _identityTap(tester, 'Start reference');
      await _shoot(tester, 'identity-draft');
      await _identityTap(tester, 'Take photo');
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, 2000),
      );
      await _shoot(tester, 'identity-preview');
    });

    testWidgets('customer saved photo ready to submit', (tester) async {
      if (!_capture) return;
      await _identity(tester, status: 'draft', version: 2, height: 1300);
      await _shoot(tester, 'identity-saved');
    });

    testWidgets('customer submitted', (tester) async {
      if (!_capture) return;
      await _identity(tester, status: 'submitted', version: 3, height: 1100);
      await _shoot(tester, 'identity-submitted');
    });

    testWidgets('customer changes requested', (tester) async {
      if (!_capture) return;
      await _identity(tester, status: 'needs_changes', version: 4);
      await _shoot(tester, 'identity-changes');
    });

    testWidgets('customer expired', (tester) async {
      if (!_capture) return;
      await _identity(
        tester,
        status: 'needs_changes',
        version: 4,
        expired: true,
      );
      await _shoot(tester, 'identity-expired');
    });

    testWidgets('customer accepted', (tester) async {
      if (!_capture) return;
      await _identity(tester, status: 'reference_accepted', version: 5);
      await _shoot(tester, 'identity-accepted');
    });

    testWidgets('officer review', (tester) async {
      if (!_capture) return;
      await _identity(
        tester,
        officer: true,
        status: 'submitted',
        version: 3,
        height: 1700,
      );
      await _shoot(tester, 'identity-officer');
    });

    testWidgets('officer confirm step', (tester) async {
      if (!_capture) return;
      await _identity(
        tester,
        officer: true,
        status: 'submitted',
        version: 3,
        height: 1300,
      );
      await _identityTap(
        tester,
        'I confirm this reference belongs to the selected customer I assisted.',
      );
      await _identityTap(tester, 'Accept reference');
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, 2000),
      );
      await _shoot(tester, 'identity-officer-confirm');
    });

    testWidgets('officer review at 200% text', (tester) async {
      if (!_capture) return;
      await _identity(
        tester,
        officer: true,
        status: 'submitted',
        version: 3,
        scale: 2,
      );
      await _shoot(tester, 'identity-officer-text200');
    });
  });
}
