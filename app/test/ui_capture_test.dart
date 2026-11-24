// Renders review/report screenshots of the main workspace screens with the
// bundled Be Vietnam Pro font. Skipped in ordinary runs; generate with:
//   flutter test test/ui_capture_test.dart --dart-define=CAPTURE_UI=true
// Images are written to the ignored ../.tmp/ui-review/ folder.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/account_history_api.dart';
import 'package:nene_app/data/assistant_api.dart';
import 'package:nene_app/data/banking_repository.dart';
import 'package:nene_app/data/branches_api.dart';
import 'package:nene_app/data/savings_policy_api.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/data/user_profile.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/session_controller.dart';

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
const _accounts = [
  BankAccount(
    id: 'checking',
    accountNumber: '100000000001',
    type: 'checking',
    currency: 'VND',
    balanceMinor: '3000000',
    status: 'active',
  ),
  BankAccount(
    id: 'saving',
    accountNumber: '100000000003',
    type: 'saving',
    currency: 'VND',
    balanceMinor: '12500000',
    status: 'active',
    isDemo: true,
    annualRateBps: 600,
    monthlyProfitMinor: '62500',
  ),
  BankAccount(
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
  ),
];

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
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: NeneApp(
        controller: session,
        banking: FakeBanking()..accounts = (_) async => _accounts,
        security: SecurityApi(
          baseUrl: _base,
          owner: credentials,
          client: _offline,
        ),
        history: AccountHistoryApi(baseUrl: _base, client: _offline),
        branches: BranchesApi(baseUrl: _base, client: _offline),
        assistant: AssistantApi(baseUrl: _base, client: _offline),
        savingsPolicy: SavingsPolicyApi(baseUrl: _base, client: _offline),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _shoot(WidgetTester tester, String name) async {
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

void main() {
  testWidgets('capture customer home', (tester) async {
    if (!_capture) return;
    await _mount(tester, _an);
    await _shoot(tester, 'customer-home');
  });

  testWidgets('capture full customer home', (tester) async {
    if (!_capture) return;
    await _mount(tester, _an, height: 1500);
    await _shoot(tester, 'customer-home-full');
  });

  testWidgets('capture customer profile tab', (tester) async {
    if (!_capture) return;
    await _mount(tester, _an);
    await tester.tap(find.text('Profile'));
    await _shoot(tester, 'customer-profile');
  });

  testWidgets('capture officer workspace', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer);
    await _shoot(tester, 'officer-home');
  });

  testWidgets('capture officer profile tab', (tester) async {
    if (!_capture) return;
    await _mount(tester, _officer);
    await tester.tap(find.text('Profile'));
    await _shoot(tester, 'officer-profile');
  });
}
