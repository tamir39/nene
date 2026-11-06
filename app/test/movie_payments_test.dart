import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:nene_app/data/payments_api.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/ui/payments_screen.dart';
import 'assistant_test.dart' as chat;
import 'payments_test.dart' as fixture;
import 'security_screen_test.dart' show Port;
import 'test_doubles.dart';

Map<String, dynamic> movie([bool evening = false]) => {
  'id': evening ? 'movie_evening_v1' : 'movie_matinee_v1',
  'name': evening
      ? 'Demo movie ticket · evening'
      : 'Demo movie ticket · matinee',
  'description': evening
      ? 'One ticket for The Little Comet at fictional Nene Cinema, demo session B. No real showing, seat reservation or admission is provided.'
      : 'One ticket for A Pocket of Sunshine at fictional Nene Cinema, demo session A. No real showing, seat reservation or admission is provided.',
  'amountMinor': evening ? '120000' : '90000',
  'currency': 'VND',
};
Map<String, dynamic> configuration({bool enabled = true}) => {
  ...fixture.configuration(enabled: enabled),
  'services': [
    fixture.service(),
    fixture.service('water'),
    fixture.service('phone'),
    movie(),
    movie(true),
  ],
};
Map<String, dynamic> preview({bool enabled = true}) => {
  'service': movie(),
  'amountMinor': '90000',
  'currency': 'VND',
  'checkoutAvailable': enabled,
  'fulfillment': 'not_available',
  'previewOnly': true,
};
Map<String, dynamic> review() => {
  ...fixture.review(),
  'service': movie(),
  'amountMinor': '90000',
};
Map<String, dynamic> order([String state = 'awaiting_payment']) => {
  ...fixture.order(state),
  'service': movie(),
  'amountMinor': '90000',
};

Future<void> selectMovie(WidgetTester tester) async {
  final button = find.text('View ticket details').first;
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'preview is read-only, bound to selection, and rejects authorization/result fields',
    () async {
      for (final change in [
        <String, dynamic>{},
        {'previewOnly': false},
        {'checkoutAvailable': 'true'},
        {'currency': 'USD'},
        {'amountMinor': '120000'},
        {'fulfillment': 'ticket_issued'},
        {'service': movie(true)},
        {'requestId': 'must-not-exist'},
        {'reviewToken': 'must-not-exist'},
        {'state': 'paid'},
      ]) {
        final api = await fixture.createApi((req) async {
          expect(req.url.path, '/api/v1/me/payments/preview');
          expect(req.body, '{"serviceId":"movie_matinee_v1"}');
          return fixture.json({...preview(enabled: false), ...change});
        });
        if (change.isEmpty) {
          final result = await api.preview('movie_matinee_v1');
          expect(result.service.isMovie, isTrue);
          expect(result.checkoutAvailable, isFalse);
        } else {
          await expectLater(
            api.preview('movie_matinee_v1'),
            throwsA(isA<SessionCoordinationException>()),
          );
        }
        expect(
          api.security.owner.session?.pair.accessToken,
          change.isEmpty ? 'test' : null,
        );
      }
    },
  );
  test('secure review and confirmation reject changed movie details', () async {
    final expected = PaymentServiceOffer.fromJson(movie());
    final api = await fixture.createApi(
      (req) async => fixture.json({
        ...review(),
        'service': {...movie(), 'description': 'Changed screening'},
      }),
    );
    await expectLater(
      api.review(expected.id, expected: expected),
      throwsA(isA<SessionCoordinationException>()),
    );
    final confirmApi = await fixture.createApi((req) async {
      if (req.url.path.endsWith('/review')) return fixture.json(review());
      return fixture.json({
        ...fixture.confirm(),
        'order': {
          ...order(),
          'service': {...movie(), 'name': 'Changed movie'},
        },
      });
    });
    final prepared = await confirmApi.review(expected.id);
    await expectLater(
      confirmApi.confirm(prepared, '123456'),
      throwsA(isA<SessionCoordinationException>()),
    );
    expect(confirmApi.security.owner.session, isNull);
  });
  testWidgets(
    'disabled movie checkout still allows details without creating an order',
    (tester) async {
      final paths = <String>[];
      final api = await fixture.createApi((req) async {
        paths.add(req.url.path);
        if (req.url.path.endsWith('/configuration')) {
          return fixture.json(configuration(enabled: false));
        }
        if (req.url.path.endsWith('/preview')) {
          return fixture.json(preview(enabled: false));
        }
        expect(req.method, 'GET');
        return fixture.json({'orders': <Map<String, dynamic>>[]});
      });
      await fixture.showScreen(tester, api, movies: true);
      expect(find.text('Demo electricity bill'), findsNothing);
      await selectMovie(tester);
      expect(find.text('Preview only'), findsOneWidget);
      expect(find.textContaining('creates no order'), findsOneWidget);
      expect(find.text('90,000 VND'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Continue to secure checkout'),
            )
            .onPressed,
        isNull,
      );
      expect(paths, [
        '/api/v1/me/payments/configuration',
        '/api/v1/me/payments/',
        '/api/v1/me/payments/preview',
      ]);
      expect(api.security.owner.session!.pair.accessToken, 'test');
      await fixture.tap(tester, 'Back to movie offers');
      expect(find.text('Ticket details'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'configured movie flow explicitly confirms then reports sandbox success without admission',
    (tester) async {
      var confirms = 0, opens = 0;
      final api = await fixture.createApi((req) async {
        if (req.url.path.endsWith('/configuration')) {
          return fixture.json(configuration());
        }
        if (req.url.path.endsWith('/payments/')) {
          return fixture.json({'orders': <Map<String, dynamic>>[]});
        }
        if (req.url.path.endsWith('/preview')) return fixture.json(preview());
        if (req.url.path.endsWith('/review')) return fixture.json(review());
        if (req.url.path.endsWith('/confirm')) {
          confirms++;
          return fixture.json({...fixture.confirm(), 'order': order()});
        }
        return fixture.json({
          'requestId': 'payment-request',
          'state': 'paid',
          'order': order('paid'),
        });
      });
      await fixture.showScreen(
        tester,
        api,
        movies: true,
        open: (_) async {
          opens++;
          return true;
        },
      );
      await selectMovie(tester);
      expect(confirms, 0);
      await fixture.tap(tester, 'Continue to secure checkout');
      expect(find.text('Review sandbox checkout'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456');
      await fixture.tap(tester, 'Confirm sandbox checkout');
      expect(confirms, 1);
      expect(opens, 0);
      await fixture.tap(tester, 'Open VNPay sandbox');
      expect(opens, 1);
      await fixture.tap(tester, 'Check payment status');
      expect(find.text('Sandbox payment successful'), findsOneWidget);
      expect(
        find.textContaining(
          'No real ticket, seat reservation or cinema admission was issued.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final state in ['awaiting_payment', 'paid', 'failed']) {
    testWidgets(
      'movie $state history only blocks a new checkout while pending',
      (tester) async {
        final api = await fixture.createApi((req) async {
          if (req.url.path.endsWith('/configuration')) {
            return fixture.json(configuration());
          }
          if (req.url.path.endsWith('/preview')) return fixture.json(preview());
          return fixture.json({
            'orders': [fixture.order('paid'), order(state)],
          });
        });
        await fixture.showScreen(tester, api, movies: true);
        await selectMovie(tester);
        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Continue to secure checkout'),
        );
        expect(button.onPressed == null, state == 'awaiting_payment');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'home movie destination returns to an unchanged bills destination',
    (tester) async {
      final session = await chat.owner();
      final credentials = SessionOwner(Port());
      await credentials.signIn('', '');
      addTearDown(credentials.dispose);
      await tester.pumpWidget(
        NeneApp(
          controller: session,
          banking: FakeBanking(),
          security: SecurityApi(
            baseUrl: chat.base,
            owner: credentials,
            client: MockClient((req) async {
              expect(req.method, 'GET');
              return fixture.json(
                req.url.path.endsWith('/configuration')
                    ? configuration(enabled: false)
                    : {'orders': <Map<String, dynamic>>[]},
              );
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await chat.tap(tester, 'Movie tickets demo');
      expect(
        tester.widget<PaymentsScreen>(find.byType(PaymentsScreen)).movies,
        isTrue,
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await chat.tap(tester, 'Bills & phone demo');
      expect(
        tester.widget<PaymentsScreen>(find.byType(PaymentsScreen)).movies,
        isFalse,
      );
      expect(find.text('Demo movie ticket · matinee'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'renders a narrow movie preview with readable labels and no real-ticket claim',
    (tester) async {
      if (!const bool.fromEnvironment('CAPTURE_MOVIES_UI')) return;
      final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
      await tester.runAsync(() async {
        for (final font in {
          'PaymentFixtureFont': 'roboto-regular.ttf',
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
      final api = await fixture.createApi((req) async {
        if (req.url.path.endsWith('/configuration')) {
          return fixture.json(configuration(enabled: false));
        }
        if (req.url.path.endsWith('/preview')) {
          return fixture.json(preview(enabled: false));
        }
        return fixture.json({'orders': <Map<String, dynamic>>[]});
      });
      await fixture.showScreen(tester, api, movies: true, capture: true);
      await selectMovie(tester);
      final scrollable = find.byType(Scrollable).first;
      await tester.drag(scrollable, const Offset(0, 1000));
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('payment-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../.tmp/ui-review/movie-preview.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
