// Renders review/report screenshots of the payments, savings-rate and
// demo-account screens with the bundled Be Vietnam Pro font. Skipped in
// ordinary runs; generate with:
//   flutter test test/ui_capture_payments_test.dart --dart-define=CAPTURE_UI=true
// Images are written to the ignored ../.tmp/ui-review/ folder.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/demo_accounts_api.dart';
import 'package:nene_app/data/payments_api.dart';
import 'package:nene_app/data/savings_policy_api.dart';
import 'package:nene_app/session_controller.dart';
import 'package:nene_app/ui/demo_account_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';
import 'package:nene_app/ui/payments_screen.dart';
import 'package:nene_app/ui/savings_policy_screen.dart';

import 'movie_payments_test.dart' as movies;
import 'payments_test.dart' as fixture;
import 'test_doubles.dart';

const _capture = bool.fromEnvironment('CAPTURE_UI');
final _base = Uri.parse('http://localhost/api/v1/');
const _key = ValueKey('ui-capture');

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

/// Mounts one screen inside the workspace chrome (back, logo, sign out).
Future<void> _mount(
  WidgetTester tester,
  Widget body, {
  double height = 844,
}) async {
  tester.view.physicalSize = Size(390, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await _fonts(tester);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: neneTheme(),
        home: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: IconButton(
              tooltip: 'Back',
              onPressed: () {},
              icon: const Icon(Icons.arrow_back),
            ),
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
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _shoot(WidgetTester tester, String name, {double? height}) async {
  if (height != null) tester.view.physicalSize = Size(390, height);
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_key));
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

Future<void> _tap(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _top(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 4000));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _order(String id, String service, String state, int day) {
  final offer = fixture.service(service);
  return {
    ...fixture.order(state),
    'id': id,
    'service': offer,
    'amountMinor': offer['amountMinor'],
    'createdAt': DateTime(2026, 11, day, 9 + day % 8, 12).toIso8601String(),
  };
}

Future<PaymentsApi> _paymentsApi({
  bool enabled = true,
  List<Map<String, dynamic>> orders = const [],
  bool movieCatalog = false,
}) {
  var paid = false;
  return fixture.createApi((req) async {
    final path = req.url.path;
    if (path.endsWith('/configuration')) {
      return fixture.json(
        movieCatalog
            ? movies.configuration(enabled: enabled)
            : fixture.configuration(enabled: enabled),
      );
    }
    if (path.endsWith('/payments/')) return fixture.json({'orders': orders});
    if (path.endsWith('/preview')) {
      return fixture.json(movies.preview(enabled: enabled));
    }
    if (path.endsWith('/review')) return fixture.json(fixture.review());
    if (path.endsWith('/confirm')) {
      paid = true;
      return fixture.json(fixture.confirm());
    }
    return fixture.json({
      'requestId': 'payment-request',
      'state': paid ? 'paid' : 'awaiting_payment',
      'order': fixture.order(paid ? 'paid' : 'awaiting_payment'),
    });
  });
}

Future<SessionController> _officer() async {
  final session = SessionController(
    auth: FakeAuth()
      ..userId = officerProfile.id
      ..accessToken = 'test-token',
    profiles: FakeProfiles()..fetch = (_) async => officerProfile,
  );
  await session.loadProfile();
  return session;
}

void main() {
  testWidgets('capture bills catalog while sandbox is not configured', (
    tester,
  ) async {
    if (!_capture) return;
    final api = await _paymentsApi(enabled: false);
    await _mount(tester, PaymentsScreen(api: api), height: 1720);
    await _shoot(tester, 'payments-bills-disabled');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('capture bills catalog with recent payments', (tester) async {
    if (!_capture) return;
    final api = await _paymentsApi(
      orders: [
        _order('order-phone', 'phone', 'awaiting_payment', 24),
        _order('order-water', 'water', 'paid', 21),
        _order('order-power', 'electricity', 'failed', 18),
      ],
    );
    await _mount(
      tester,
      PaymentsScreen(api: api, initialService: 'phone'),
      height: 2130,
    );
    await _shoot(tester, 'payments-bills');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('capture review, pending hand-off and paid status', (
    tester,
  ) async {
    if (!_capture) return;
    final api = await _paymentsApi();
    await _mount(
      tester,
      PaymentsScreen(api: api, openCheckout: (_) async => true),
      height: 1000,
    );
    await _tap(tester, find.text('Review electricity bill'));
    await tester.enterText(find.byType(TextField), '1234');
    await _top(tester);
    await _shoot(tester, 'payments-review');
    await tester.enterText(find.byType(TextField), '123456');
    await _tap(tester, find.text('Confirm sandbox checkout'));
    await _top(tester);
    await _shoot(tester, 'payments-status-pending', height: 1250);
    await _tap(tester, find.text('Check payment status'));
    await _top(tester);
    await _shoot(tester, 'payments-status-paid', height: 1060);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('capture movie offers and ticket preview', (tester) async {
    if (!_capture) return;
    final api = await _paymentsApi(enabled: false, movieCatalog: true);
    await _mount(tester, PaymentsScreen(api: api, movies: true), height: 1560);
    await _shoot(tester, 'payments-movies');
    await _tap(tester, find.text('View ticket details').first);
    await _top(tester);
    await _shoot(tester, 'payments-movie-preview', height: 1020);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('capture officer savings rate form', (tester) async {
    if (!_capture) return;
    final session = await _officer();
    addTearDown(session.dispose);
    final api = SavingsPolicyApi(
      baseUrl: _base,
      client: MockClient(
        (req) async => http.Response(
          req.method == 'PATCH'
              ? '{"annualRateBps":625,"revision":4}'
              : '{"annualRateBps":600,"revision":3}',
          200,
        ),
      ),
    );
    await _mount(tester, SavingsPolicyScreen(session: session, api: api));
    await _shoot(tester, 'payments-savings-rate');
    await tester.enterText(find.byType(TextField).at(0), '6.25');
    await tester.enterText(
      find.byType(TextField).at(1),
      'Annual policy review',
    );
    await _tap(tester, find.text('Save savings rate'));
    await _top(tester);
    await _shoot(tester, 'payments-savings-rate-saved');
  });

  testWidgets('capture officer demo account form', (tester) async {
    if (!_capture) return;
    final session = await _officer();
    addTearDown(session.dispose);
    final api = DemoAccountsApi(
      baseUrl: _base,
      client: MockClient((_) async => http.Response('{}', 503)),
    );
    await _mount(
      tester,
      DemoAccountScreen(
        session: session,
        api: api,
        customerId: 'b3000000-0000-4000-8000-000000000002',
        customerName: 'Nguyễn Văn An',
        onDone: () {},
      ),
      height: 940,
    );
    await _shoot(tester, 'payments-demo-savings');
    await _tap(tester, find.text('Mortgage'));
    final fields = find.byType(TextField);
    for (final (index, value) in [
      (0, '480000000'),
      (1, '120'),
      (2, '2026-12-15'),
      (3, 'Mortgage view testing'),
    ]) {
      await tester.enterText(fields.at(index), value);
    }
    await _tap(tester, find.byType(CheckboxListTile));
    tester.view.physicalSize = const Size(390, 1340);
    await _top(tester);
    await _shoot(tester, 'payments-demo-mortgage');
  });
}
