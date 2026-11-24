// Renders review/report screenshots of the officer forms and pages (plus the
// customer contact form and assistant account chooser that share them) with
// the bundled Be Vietnam Pro font. Skipped in ordinary runs; generate with:
//   flutter test test/ui_capture_officer_test.dart --dart-define=CAPTURE_UI=true
// Images are written to the ignored ../.tmp/ui-review/ folder.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/assistant_api.dart';
import 'package:nene_app/data/banking_repository.dart';
import 'package:nene_app/data/demo_accounts_api.dart';
import 'package:nene_app/data/profile_api.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/data/user_profile.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/session_controller.dart';

import 'identity_test_doubles.dart';
import 'security_screen_test.dart' show Port;
import 'test_doubles.dart';

const _capture = bool.fromEnvironment('CAPTURE_UI');
final _base = Uri.parse('http://localhost/api/v1/');
final _offline = MockClient((_) async => http.Response('{}', 404));
const _key = ValueKey('ui-capture');

const _an = UserProfile(
  id: 'user-id',
  email: 'an@example.invalid',
  displayName: 'Nguyễn Văn An',
  role: AppRole.customer,
  phone: '+84 901 000 001',
  address: 'Quận 7, TP. Hồ Chí Minh',
);
const _officer = UserProfile(
  id: 'officer-id',
  email: 'officer@example.invalid',
  displayName: 'Nene Officer',
  role: AppRole.officer,
);
const _checking = BankAccount(
  id: 'checking',
  accountNumber: '100000000001',
  type: 'checking',
  currency: 'VND',
  balanceMinor: '0',
  status: 'active',
);
const _saving = BankAccount(
  id: 'saving',
  accountNumber: '100000000003',
  type: 'saving',
  currency: 'VND',
  balanceMinor: '12500000',
  status: 'active',
  isDemo: true,
  annualRateBps: 600,
  monthlyProfitMinor: '62500',
);
const _mortgage = BankAccount(
  id: 'mortgage',
  accountNumber: '100000000004',
  type: 'mortgage',
  currency: 'VND',
  balanceMinor: '0',
  status: 'active',
  isDemo: true,
  monthlyDueMinor: '4250000',
  nextDueOn: '2026-12-15',
  principalRemainingMinor: '480000000',
);
const _binh = CustomerDetail(
  id: 'customer-binh',
  email: 'binh.tran@example.invalid',
  displayName: 'Trần Thị Bình',
  phone: '+84 902 000 002',
  address: '19 Nguyễn Hữu Thọ, Quận 7, TP. Hồ Chí Minh',
  accounts: [_checking, _saving],
);
const _results = <CustomerSummary>[
  _binh,
  CustomerSummary(
    id: 'customer-binh-2',
    email: 'binh.le@example.invalid',
    displayName: 'Lê Văn Bình',
  ),
  CustomerSummary(
    id: 'customer-binh-3',
    email: 'binh.pham@example.invalid',
    displayName: 'Phạm Ngọc Bình An',
  ),
];

FakeBanking _banking() {
  final banking = FakeBanking();
  banking.accounts = (_) async => const [_checking, _saving, _mortgage];
  banking.search = (_) async => _results;
  banking.detail = (_) async => _binh;
  banking.create = (_, _) async => _binh;
  return banking;
}

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

Future<void> _mount(
  WidgetTester tester,
  UserProfile profile, {
  FakeBanking? banking,
  AssistantApi? assistant,
  double height = 844,
}) async {
  tester.view.physicalSize = Size(390, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await _fonts(tester);
  final session = SessionController(
    auth: FakeAuth()
      ..userId = profile.id
      ..accessToken = 'test-token',
    profiles: FakeProfiles()..fetch = (_) async => profile,
  );
  await session.loadProfile();
  final credentials = SessionOwner(Port());
  await credentials.signIn('', '');
  addTearDown(credentials.dispose);
  final officer = profile.role == AppRole.officer;
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: NeneApp(
        controller: session,
        banking: banking ?? _banking(),
        identity: officer ? FakeIdentity() : null,
        demoAccounts: officer
            ? DemoAccountsApi(baseUrl: _base, client: _offline)
            : null,
        security: SecurityApi(
          baseUrl: _base,
          owner: credentials,
          client: _offline,
        ),
        assistant: assistant,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  final target = find.text(text).first;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _fillCreation(WidgetTester tester) async {
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), 'Trần Thị Bình');
  await tester.enterText(fields.at(1), 'Binh.Tran@example.invalid');
  await tester.enterText(fields.at(2), '+84 902 000 002');
  await tester.enterText(fields.at(3), '19 Nguyễn Hữu Thọ, Quận 7');
  await tester.enterText(fields.at(4), 'synthetic-demo-password');
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester) async {
  await _tap(tester, 'Find a customer');
  await tester.enterText(find.byType(TextField), 'Bình');
  await _tap(tester, 'Search customers');
}

Future<void> _shoot(
  WidgetTester tester,
  String name, {
  bool settle = true,
}) async {
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // A spinner never settles: advance frames until other animations finish.
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }
  // Captures start at the top of the page, like a freshly opened screen.
  for (final scrollable in tester.stateList<ScrollableState>(
    find.byType(Scrollable),
  )) {
    if (scrollable.position.pixels != 0) scrollable.position.jumpTo(0);
  }
  await tester.pump();
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

void main() {
  testWidgets('capture create customer details step', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer, height: 1320);
    await _tap(tester, 'Create customer');
    await _shoot(tester, 'officer-create');
  });

  testWidgets('capture create customer validation errors', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer, height: 1440);
    await _tap(tester, 'Create customer');
    await tester.enterText(find.byType(TextFormField).at(1), 'not-an-email');
    await _tap(tester, 'Review customer');
    await _shoot(tester, 'officer-create-invalid');
  });

  testWidgets('capture create customer review step', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer, height: 1100);
    await _tap(tester, 'Create customer');
    await _fillCreation(tester);
    await _tap(tester, 'Review customer');
    await _shoot(tester, 'officer-create-review');
  });

  testWidgets('capture uncertain creation retry', (tester) async {
    if (!_capture) return;
    await _mount(
      tester,
      _officer,
      height: 1280,
      banking: FakeBanking()
        ..create = (_, _) async =>
            throw const ApiException(ApiFailure.unavailable),
    );
    await _tap(tester, 'Create customer');
    await _fillCreation(tester);
    await _tap(tester, 'Review customer');
    await _tap(tester, 'Confirm and create');
    await _shoot(tester, 'officer-create-retry');
  });

  testWidgets('capture search before a query', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer);
    await _tap(tester, 'Find a customer');
    await _shoot(tester, 'officer-search-start');
  });

  testWidgets('capture search loading', (tester) async {
    if (!_capture) return;
    await _mount(
      tester,
      _officer,
      banking: FakeBanking()
        ..search = (_) => Completer<List<CustomerSummary>>().future,
    );
    await _tap(tester, 'Find a customer');
    await tester.enterText(find.byType(TextField), 'Bình');
    await tester.tap(find.text('Search customers'));
    await _shoot(tester, 'officer-search-loading', settle: false);
  });

  testWidgets('capture search results', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer);
    await _search(tester);
    await _shoot(tester, 'officer-search');
  });

  testWidgets('capture search without matches', (tester) async {
    if (!_capture) return;
    await _mount(
      tester,
      _officer,
      banking: FakeBanking()..search = (_) async => [],
    );
    await _search(tester);
    await _shoot(tester, 'officer-search-none');
  });

  testWidgets('capture search failure', (tester) async {
    if (!_capture) return;
    await _mount(
      tester,
      _officer,
      banking: FakeBanking()
        ..search = (_) async =>
            throw const ApiException(ApiFailure.unavailable),
    );
    await _search(tester);
    await _shoot(tester, 'officer-search-error');
  });

  testWidgets('capture customer detail', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer, height: 1900);
    await _search(tester);
    await _tap(tester, 'View customer');
    await _shoot(tester, 'officer-detail');
  });

  testWidgets('capture customer detail after creation', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer, height: 1500);
    await _tap(tester, 'Create customer');
    await _fillCreation(tester);
    await _tap(tester, 'Review customer');
    await _tap(tester, 'Confirm and create');
    await _shoot(tester, 'officer-detail-created');
  });

  testWidgets('capture requested change form', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer, height: 1080);
    await _search(tester);
    await _tap(tester, 'View customer');
    await _tap(tester, 'Make a requested change');
    await _shoot(tester, 'officer-edit');
  });

  testWidgets('capture requested change validation', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer, height: 1120);
    await _search(tester);
    await _tap(tester, 'View customer');
    await _tap(tester, 'Make a requested change');
    await _tap(tester, 'Save requested changes');
    await _shoot(tester, 'officer-edit-invalid');
  });

  testWidgets('capture customer contact form', (tester) async {
    if (!_capture) return;
    await _mount(tester, _an);
    await _tap(tester, 'Profile');
    await _tap(tester, 'Edit contact details');
    await _shoot(tester, 'officer-contact');
  });

  testWidgets('capture customer contact save failure', (tester) async {
    if (!_capture) return;
    await _mount(
      tester,
      _an,
      banking: FakeBanking()
        ..contact = (_, _) async =>
            throw const ApiException(ApiFailure.unavailable),
    );
    await _tap(tester, 'Profile');
    await _tap(tester, 'Edit contact details');
    await _tap(tester, 'Save contact details');
    await _shoot(tester, 'officer-contact-error');
  });

  testWidgets('capture assistant account chooser', (tester) async {
    if (!_capture) return;
    await _mount(
      tester,
      _an,
      assistant: AssistantApi(
        baseUrl: _base,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'reply': 'Open the usual deposit form; nothing has been sent.',
              'actions': [
                {'type': 'deposit'},
              ],
              'context': null,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      ),
    );
    await _tap(tester, 'Assistant');
    await tester.enterText(find.byType(TextField), 'deposit');
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Open demo deposit');
    await _shoot(tester, 'officer-assistant-accounts');
  });
}
