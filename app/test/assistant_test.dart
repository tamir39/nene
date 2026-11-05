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
import 'package:nene_app/assistant_controller.dart';
import 'package:nene_app/data/account_history_api.dart';
import 'package:nene_app/data/assistant_api.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/data/confirmation_api.dart';
import 'package:nene_app/data/profile_api.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/session_controller.dart';
import 'package:nene_app/ui/assistant_screen.dart';
import 'package:nene_app/ui/confirmation_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';
import 'test_doubles.dart';
import 'security_screen_test.dart' show Port;

final base = Uri.parse('http://localhost/api/v1/');
http.Response reply({
  String text = 'Choose an activity.',
  List<Map<String, dynamic>> actions = const [],
  String? context,
}) => http.Response(
  jsonEncode({'reply': text, 'actions': actions, 'context': context}),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
AssistantApi api(Future<http.Response> Function(http.Request) handler) =>
    AssistantApi(baseUrl: base, client: MockClient(handler));
Future<SessionController> owner() async {
  final session = SessionController(
    auth: FakeAuth()
      ..userId = demoProfile.id
      ..accessToken = 'test-token',
    profiles: FakeProfiles()..fetch = (_) async => demoProfile,
  );
  await session.loadProfile();
  return session;
}

Future<void> tap(WidgetTester tester, String label) async {
  if (find.text(label).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      find.text(label),
      180,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  for (final activity in [
    AssistantActivity.transfer,
    AssistantActivity.deposit,
    AssistantActivity.withdrawal,
  ]) {
    testWidgets(
      '${activity.name} link opens the normal gated form without posting',
      (tester) async {
        final session = await owner();
        final credentials = SessionOwner(Port());
        await credentials.signIn('', '');
        addTearDown(credentials.dispose);
        final paths = <String>[];
        final root = activity == AssistantActivity.transfer
            ? 'transfers'
            : 'cash/${activity.name}';
        final security = SecurityApi(
          baseUrl: base,
          owner: credentials,
          client: MockClient((req) async {
            expect(
              req.method,
              'GET',
            ); // Opening a chat link must never create/confirm a financial intent.
            paths.add(req.url.path);
            return http.Response(
              jsonEncode(
                req.url.path.endsWith('/configuration')
                    ? <String, dynamic>{'enabled': false}
                    : <String, dynamic>{
                        activity == AssistantActivity.transfer
                                ? 'transfers'
                                : 'operations':
                            <Map<String, dynamic>>[],
                      },
              ),
              200,
            );
          }),
        );
        await tester.pumpWidget(
          NeneApp(
            controller: session,
            banking: FakeBanking(),
            security: security,
            assistant: api(
              (_) async => reply(
                actions: [
                  {'type': activity.name},
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tap(tester, 'Ask Nene');
        await tap(tester, 'Transfer money');
        await tap(tester, AssistantAction(activity).label);
        expect(paths, isEmpty);
        await tap(
          tester,
          '${demoAccount.typeLabel} · ${demoAccount.accountNumber}',
        );
        expect(paths, ['/api/v1/me/$root/configuration', '/api/v1/me/$root/']);
        final screen = tester.widget<ConfirmationScreen>(
          find.byType(ConfirmationScreen),
        );
        expect(screen.api.sendMoney, isTrue);
        expect(
          screen.api.cashOperation,
          activity == AssistantActivity.transfer
              ? null
              : activity == AssistantActivity.deposit
              ? CashOperation.deposit
              : CashOperation.withdrawal,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Review confirmation'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.text('Nene assistant'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  test(
    'reply rejects unknown destinations, URL/account fields and malformed months',
    () async {
      for (final action in [
        {'type': 'url', 'url': 'https://example.invalid'},
        {'type': 'transfer', 'accountId': 'other'},
        {'type': 'execute_payment'},
        {'type': 'history', 'month': '2026-13'},
        {'type': 'history'},
        {'type': 'deposit', 'month': '2026-10'},
      ]) {
        await expectLater(
          api((_) async => reply(actions: [action])).ask('token', 'hi'),
          throwsA(isA<ApiException>()),
        );
      }
    },
  );
  test(
    'follow-up sends only bounded context and retry does not duplicate customer message',
    () async {
      final session = await owner();
      addTearDown(session.dispose);
      var calls = 0;
      final chat = AssistantController(
        session: session,
        api: api((req) async {
          expect(req.followRedirects, isFalse);
          expect(req.headers['Authorization'], 'Bearer test-token');
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          calls++;
          if (calls == 1) {
            expect(body, {'message': 'history'});
            return reply(text: 'Which month?', context: 'history_month');
          }
          expect(body, {'message': '2026-10', 'context': 'history_month'});
          if (calls == 2) return http.Response('', 503);
          return reply(
            text: 'Open history for 2026-10.',
            actions: [
              {'type': 'history', 'month': '2026-10'},
            ],
          );
        }),
      );
      addTearDown(chat.dispose);
      await chat.send('history');
      await chat.send('2026-10');
      expect(chat.error, isNotNull);
      expect(chat.messages.length, 3);
      await chat.retry();
      expect(chat.error, isNull);
      expect(chat.messages.length, 4);
      expect(chat.messages.last.actions.single.month, '2026-10');
    },
  );
  test(
    'clear/sign-out discard late results and do not retain another session conversation',
    () async {
      final session = await owner();
      addTearDown(session.dispose);
      var pending = Completer<http.Response>();
      final chat = AssistantController(
        session: session,
        api: api((_) => pending.future),
      );
      addTearDown(chat.dispose);
      final first = chat.send('history');
      chat.clear();
      pending.complete(reply(text: 'Old response'));
      await first;
      expect(chat.messages, isEmpty);
      pending = Completer<http.Response>();
      final second = chat.send('deposit');
      await session.signOut();
      pending.complete(
        reply(
          actions: [
            {'type': 'deposit'},
          ],
        ),
      );
      await second;
      expect(chat.messages, isEmpty);
      expect(chat.busy, isFalse);
    },
  );
  test('conversation has a bounded memory-only message window', () async {
    final session = await owner();
    addTearDown(session.dispose);
    final chat = AssistantController(
      session: session,
      api: api((_) async => reply()),
    );
    addTearDown(chat.dispose);
    for (var i = 0; i < 25; i++) {
      await chat.send('hello $i');
    }
    expect(chat.messages.length, 40);
    expect(chat.messages.first.text, 'hello 5');
  });
  testWidgets(
    'history action preserves month through account selection; back returns to chat; sign-out clears it',
    (tester) async {
      final session = await owner();
      var historyReads = 0;
      final history = AccountHistoryApi(
        baseUrl: base,
        client: MockClient((req) async {
          historyReads++;
          expect(req.url.path, '/api/v1/me/accounts/${demoAccount.id}/history');
          expect(req.url.queryParameters['month'], '2026-10');
          return http.Response(
            jsonEncode({
              'accountId': demoAccount.id,
              'month': '2026-10',
              'timeZone': 'Asia/Bangkok',
              'entries': <Map<String, dynamic>>[],
              'nextCursor': null,
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        NeneApp(
          controller: session,
          banking: FakeBanking(),
          history: history,
          assistant: api(
            (_) async => reply(
              text: 'Choose your account for 2026-10.',
              actions: [
                {'type': 'history', 'month': '2026-10'},
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'Ask Nene');
      await tester.enterText(find.byType(TextField), 'history October 2026');
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      await tap(tester, 'View history · 2026-10');
      expect(find.text('Choose your account'), findsOneWidget);
      expect(historyReads, 0);
      await tap(
        tester,
        '${demoAccount.typeLabel} · ${demoAccount.accountNumber}',
      );
      expect(historyReads, 1);
      expect(find.text('History for 2026-10'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('history October 2026'), findsOneWidget);
      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Nene assistant'), findsNothing);
      expect(find.text('history October 2026'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'no eligible account or unavailable activity cannot bypass into a transaction',
    (tester) async {
      final session = await owner();
      await tester.pumpWidget(
        NeneApp(
          controller: session,
          banking: FakeBanking()..accounts = (_) async => [],
          history: AccountHistoryApi(
            baseUrl: base,
            client: MockClient(
              (_) async => throw StateError('Must not read history'),
            ),
          ),
          assistant: api(
            (_) async => reply(
              actions: [
                {'type': 'history', 'month': '2026-10'},
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'Ask Nene');
      await tap(tester, 'History last month');
      await tap(tester, 'View history · 2026-10');
      expect(
        find.text('No eligible accounts are available for this activity.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'chat is usable at narrow width and large text; action buttons only navigate',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = await owner();
      addTearDown(session.dispose);
      var calls = 0, opened = 0;
      final chat = AssistantController(
        session: session,
        api: api((_) async {
          calls++;
          return reply(
            text: 'Open the usual transfer form; nothing has been sent.',
            actions: [
              {'type': 'transfer'},
            ],
          );
        }),
      );
      addTearDown(chat.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: neneTheme(),
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(2)),
              child: AssistantScreen(
                controller: chat,
                onAction: (action) {
                  expect(action.activity, AssistantActivity.transfer);
                  opened++;
                },
              ),
            ),
          ),
        ),
      );
      await tap(tester, 'Transfer money');
      expect(calls, 1);
      expect(opened, 0);
      await tap(tester, 'Open demo transfer');
      expect(opened, 1);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('assistant visual evidence with synthetic conversation', (
    tester,
  ) async {
    if (!const bool.fromEnvironment('CAPTURE_ASSISTANT_UI')) return;
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
    await tester.runAsync(() async {
      for (final font in {
        'AssistantFixtureFont': 'roboto-regular.ttf',
        'MaterialIcons': 'MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)..addFont(
              File(
                '$sdk/bin/cache/artifacts/material_fonts/${font.value}',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      }
    });
    final session = await owner();
    addTearDown(session.dispose);
    final chat = AssistantController(
      session: session,
      api: api(
        (_) async => reply(
          text:
              'Open your transaction history for 2026-10, then choose one of your accounts. Only posted transactions for that month will be shown.',
          actions: [
            {'type': 'history', 'month': '2026-10'},
          ],
        ),
      ),
    );
    addTearDown(chat.dispose);
    await chat.send('Show my history for October 2026');
    const key = ValueKey('assistant-capture');
    final theme = neneTheme();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'AssistantFixtureFont'),
        ),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            appBar: AppBar(title: const NeneLogo(size: 30)),
            body: AssistantScreen(controller: chat, onAction: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../.tmp/ui-review/assistant-fixture.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
}
