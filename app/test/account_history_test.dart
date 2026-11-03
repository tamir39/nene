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
import 'package:nene_app/data/account_history_api.dart';
import 'package:nene_app/data/banking_repository.dart';
import 'package:nene_app/data/profile_api.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/session_controller.dart';
import 'package:nene_app/ui/account_history_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';
import 'test_doubles.dart';

const account = BankAccount(
  id: 'account-id',
  accountNumber: '100000000001',
  type: 'checking',
  currency: 'VND',
  balanceMinor: '0',
  status: 'active',
);
Map<String, dynamic> entry(int i) => {
  'id': 'entry-$i',
  'reference': 'synthetic-reference-$i',
  'kind': 'transfer',
  'direction': i.isEven ? 'credit' : 'debit',
  'amountMinor': '9007199254740993',
  'currency': 'VND',
  'postedAt': '2026-10-31T17:00:00.000000Z',
};
http.Response page(
  http.Request req,
  List<Map<String, dynamic>> rows, {
  String? cursor,
}) => http.Response(
  jsonEncode({
    'accountId': req.url.pathSegments[4],
    'month': req.url.queryParameters['month'],
    'timeZone': 'Asia/Bangkok',
    'entries': rows,
    'nextCursor': cursor,
  }),
  200,
);
AccountHistoryApi api(Future<http.Response> Function(http.Request) handler) =>
    AccountHistoryApi(
      baseUrl: Uri.parse('http://localhost/api/v1/'),
      client: MockClient(handler),
    );
Future<SessionController> session() async {
  final result = SessionController(
    auth: FakeAuth()
      ..userId = demoProfile.id
      ..accessToken = 'test-token',
    profiles: FakeProfiles()..fetch = (_) async => demoProfile,
  );
  await result.loadProfile();
  return result;
}

Future<void> tap(WidgetTester tester, String label) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_HISTORY_UI')) return;
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
    await (FontLoader('HistoryTestFont')..addFont(
          File(
            '$sdk/bin/cache/artifacts/material_fonts/roboto-regular.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  testWidgets('history visual evidence uses synthetic entries', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE_HISTORY_UI')) return;
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final owner = await session();
    addTearDown(owner.dispose);
    final theme = neneTheme();
    const captureKey = ValueKey('history-capture');
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'HistoryTestFont'),
          filledButtonTheme: FilledButtonThemeData(
            style: theme.filledButtonTheme.style!.copyWith(
              textStyle: const WidgetStatePropertyAll(
                TextStyle(fontFamily: 'HistoryTestFont', fontSize: 16),
              ),
            ),
          ),
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: Scaffold(
            appBar: AppBar(title: const Text('Synthetic history fixture')),
            body: AccountHistoryScreen(
              session: owner,
              api: api(
                (req) async => page(req, [
                  {...entry(0), 'amountMinor': '100000'},
                  {...entry(1), 'amountMinor': '50000'},
                ]),
              ),
              account: account,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '2026-11');
    await tap(tester, 'Show month');
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../.tmp/history-ui/history.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
  test(
    'history response fails closed for wrong account, malformed amounts and wrong timezone',
    () async {
      for (final change in [
        {'accountId': 'other'},
        {'timeZone': 'UTC'},
        {
          'entries': [
            {...entry(1), 'amountMinor': 1},
          ],
        },
        {
          'entries': [entry(1)],
          'nextCursor': 'entry-1',
        },
      ]) {
        final client = api(
          (req) async => http.Response(
            jsonEncode({
              'accountId': account.id,
              'month': '2026-11',
              'timeZone': 'Asia/Bangkok',
              'entries': <Map<String, dynamic>>[],
              'nextCursor': null,
              ...change,
            }),
            200,
          ),
        );
        await expectLater(
          client.read('token', account.id, '2026-11'),
          throwsA(isA<ApiException>()),
        );
      }
      expect(HistoryEntry(entry(1)).timeLabel, '2026-11-01 00:00 (UTC+07)');
    },
  );
  testWidgets('customer opens empty history from account card and returns', (
    tester,
  ) async {
    final auth = FakeAuth()
      ..userId = demoProfile.id
      ..accessToken = 'test-token';
    final owner = SessionController(
      auth: auth,
      profiles: FakeProfiles()..fetch = (_) async => demoProfile,
    );
    final history = api((req) async {
      expect(req.headers['Authorization'], 'Bearer test-token');
      return page(req, []);
    });
    await tester.pumpWidget(
      NeneApp(controller: owner, banking: FakeBanking(), history: history),
    );
    await tester.pumpAndSettle();
    await tap(tester, 'View history · 100000000001');
    expect(find.text('Transaction history'), findsOneWidget);
    expect(find.textContaining('No posted transactions'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Refresh accounts'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });
  testWidgets(
    'history paginates, keeps exact money, changes month and distinguishes failure from empty',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final owner = await session();
      addTearDown(owner.dispose);
      var calls = 0, failMore = true, rejectMonth = false;
      final history = api((req) async {
        calls++;
        if (rejectMonth) {
          return http.Response('{}', 503);
        }
        if (req.url.queryParameters['cursor'] != null) {
          expect(req.url.queryParameters['cursor'], 'entry-24');
          if (failMore) return http.Response('{}', 503);
          return page(req, [entry(25)]);
        }
        return page(req, List.generate(25, entry), cursor: 'entry-24');
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: AccountHistoryScreen(
                session: owner,
                api: history,
                account: account,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('9,007,199,254,740,993 VND'),
        findsNWidgets(25),
      );
      await tap(tester, 'Load more');
      expect(find.textContaining('Could not load more'), findsOneWidget);
      expect(find.textContaining('Transaction reference'), findsNWidgets(25));
      failMore = false;
      await tap(tester, 'Load more');
      expect(find.textContaining('Transaction reference'), findsNWidgets(26));
      expect(find.text('Load more'), findsNothing);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '2026-13');
      final previous = calls;
      await tap(tester, 'Show month');
      expect(calls, previous);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '2026-12');
      rejectMonth = true;
      await tap(tester, 'Show month');
      expect(
        find.textContaining('Could not load this account'),
        findsOneWidget,
      );
      expect(find.textContaining('No posted transactions'), findsNothing);
      expect(find.text('Transaction reference'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('late history after sign-out is discarded', (tester) async {
    final owner = await session();
    addTearDown(owner.dispose);
    final pending = Completer<http.Response>();
    http.Request? request;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountHistoryScreen(
            session: owner,
            api: api((req) {
              request = req;
              return pending.future;
            }),
            account: account,
          ),
        ),
      ),
    );
    await tester.pump();
    await owner.signOut();
    pending.complete(page(request!, [entry(1)]));
    await tester.pumpAndSettle();
    expect(find.text('Transaction reference'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
