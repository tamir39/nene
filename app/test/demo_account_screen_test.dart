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
import 'package:nene_app/data/demo_accounts_api.dart';
import 'package:nene_app/session_controller.dart';
import 'package:nene_app/ui/demo_account_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';
import 'test_doubles.dart';

const customer = 'b3000000-0000-4000-8000-000000000002';
const success =
    '{"accountId":"b3000000-0000-4000-8000-000000000003","customerId":"$customer"}';
Future<SessionController> officerSession() async {
  final session = SessionController(
    auth: FakeAuth()
      ..userId = officerProfile.id
      ..accessToken = 'test-token',
    profiles: FakeProfiles()..fetch = (_) async => officerProfile,
  );
  await session.loadProfile();
  return session;
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_DEMO_UI')) return;
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
    for (final (family, file) in [
      ('NeneTestRoboto', 'roboto-regular.ttf'),
      ('MaterialIcons', 'materialicons-regular.otf'),
    ]) {
      await (FontLoader(family)..addFont(
            File(
              '$sdk/bin/cache/artifacts/material_fonts/$file',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
    }
  });
  testWidgets('demo form visual captures', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE_DEMO_UI')) return;
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = await officerSession();
    addTearDown(session.dispose);
    const captureKey = ValueKey('demo-capture');
    await tester.pumpWidget(
      MaterialApp(
        theme: neneTheme().copyWith(
          textTheme: neneTheme().textTheme.apply(fontFamily: 'NeneTestRoboto'),
          filledButtonTheme: FilledButtonThemeData(
            style: neneTheme().filledButtonTheme.style!.copyWith(
              textStyle: const WidgetStatePropertyAll(
                TextStyle(
                  fontFamily: 'NeneTestRoboto',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: Scaffold(
            appBar: AppBar(title: const NeneLogo(size: 30)),
            body: DemoAccountScreen(
              session: session,
              api: DemoAccountsApi(
                baseUrl: Uri.parse('http://localhost/api/v1/'),
                client: MockClient((_) async => http.Response('{}', 503)),
              ),
              customerId: customer,
              customerName: 'Nene Test Customer',
              onDone: () {},
            ),
          ),
        ),
      ),
    );
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../.tmp/demo-account-ui/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('saving');
    await tapVisible(tester, find.byType(DropdownButtonFormField<String>));
    await tapVisible(tester, find.text('Mortgage').last);
    await capture('mortgage');
    await tester.ensureVisible(find.text('Check customer'));
    await capture('mortgage-actions');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'invalid saving is local; uncertain save locks details and retries identical request',
    (tester) async {
      final session = await officerSession();
      addTearDown(session.dispose);
      final requests = <http.Request>[];
      var done = 0;
      final api = DemoAccountsApi(
        baseUrl: Uri.parse('http://localhost/api/v1/'),
        client: MockClient((req) async {
          requests.add(req);
          return http.Response(
            requests.length == 1 ? '{}' : success,
            requests.length == 1 ? 503 : 201,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DemoAccountScreen(
              session: session,
              api: api,
              customerId: customer,
              customerName: 'Synthetic Customer',
              onDone: () => done++,
            ),
          ),
        ),
      );
      await tapVisible(tester, find.text('Create demo account'));
      expect(requests, isEmpty);
      expect(
        find.textContaining('Confirm synthetic data and enter'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'View testing');
      await tapVisible(tester, find.byType(CheckboxListTile));
      await tapVisible(tester, find.text('Create demo account'));
      expect(done, 0);
      expect(requests.length, 1);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);
      await tapVisible(tester, find.text('Retry same request'));
      expect(done, 1);
      expect(requests.length, 2);
      expect(requests[0].body, requests[1].body);
      expect(
        requests[0].headers['Idempotency-Key'],
        requests[1].headers['Idempotency-Key'],
      );
      expect(
        requests[0].headers['Idempotency-Key'],
        matches(RegExp(r'^[0-9a-f-]{36}$')),
      );
      expect(requests[0].headers['Authorization'], 'Bearer test-token');
      expect(jsonDecode(requests[0].body), {
        'type': 'saving',
        'reason': 'View testing',
        'syntheticConfirmed': true,
      });
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'mortgage validates date and renders at narrow width and large text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = await officerSession();
      addTearDown(session.dispose);
      final requests = <http.Request>[];
      final api = DemoAccountsApi(
        baseUrl: Uri.parse('http://localhost/api/v1/'),
        client: MockClient((req) async {
          requests.add(req);
          return http.Response('{}', 409);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: DemoAccountScreen(
                session: session,
                api: api,
                customerId: customer,
                customerName: 'Synthetic Customer',
                onDone: () {},
              ),
            ),
          ),
        ),
      );
      await tapVisible(tester, find.byType(DropdownButtonFormField<String>));
      await tapVisible(tester, find.text('Mortgage').last);
      final fields = find.byType(TextField);
      for (final (index, value) in [
        (0, '1000000'),
        (1, '3'),
        (2, '2026-02-30'),
        (3, 'Sample loan view'),
      ]) {
        await tester.ensureVisible(fields.at(index));
        await tester.enterText(fields.at(index), value);
      }
      await tapVisible(tester, find.byType(CheckboxListTile));
      await tapVisible(tester, find.text('Create demo account'));
      expect(requests, isEmpty);
      await tester.ensureVisible(fields.at(2));
      await tester.enterText(fields.at(2), '2026-12-01');
      await tapVisible(tester, find.text('Create demo account'));
      expect(requests.length, 1);
      final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
      expect(body['principalMinor'], '1000000');
      expect(body['termMonths'], 3);
      expect(body['firstDueOn'], '2026-12-01');
      expect(
        find.textContaining('This account could not be added'),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'pending duplicate tap sends once and late success after sign-out does not navigate',
    (tester) async {
      final session = await officerSession();
      addTearDown(session.dispose);
      final reply = Completer<http.Response>();
      var calls = 0, done = 0;
      final api = DemoAccountsApi(
        baseUrl: Uri.parse('http://localhost/api/v1/'),
        client: MockClient((req) {
          calls++;
          return reply.future;
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DemoAccountScreen(
              session: session,
              api: api,
              customerId: customer,
              customerName: 'Synthetic',
              onDone: () => done++,
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'View testing');
      await tapVisible(tester, find.byType(CheckboxListTile));
      await tester.ensureVisible(find.text('Create demo account'));
      await tester.pumpAndSettle();
      final submit = tester
          .widget<FilledButton>(find.byType(FilledButton))
          .onPressed!;
      submit();
      submit();
      await tester.pump();
      expect(calls, 1);
      await session.signOut();
      reply.complete(http.Response(success, 201));
      await tester.pumpAndSettle();
      expect(done, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
