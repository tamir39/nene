import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/data/smart_otp.dart';
import 'package:nene_app/data/totp.dart';
import 'package:nene_app/ui/security_screen.dart';

import 'confirmation_screen_test.dart' as confirmation;
import 'security_management_test.dart' as management;
import 'security_screen_test.dart' show Port;

/// RFC 6238 appendix B seed "12345678901234567890" in base32.
const rfcSecret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
const otherSecret = 'JBSWY3DPEHPK3PXP';

class MemoryKeys implements SmartOtpKeys {
  final values = <String, String>{};
  @override
  Future<bool> has(String name) async => values.containsKey(name);
  @override
  Future<String?> read(String name) async => values[name];
  @override
  Future<void> write(String name, String value) async => values[name] = value;
  @override
  Future<void> delete(String name) async => values.remove(name);
}

/// Smart OTP with in-memory keys, a controllable clock and unlock answer.
class Harness {
  Harness({this.allow = true, this.supported = true});
  bool allow, supported;
  final keys = MemoryKeys();
  var now = DateTime.utc(2026, 11, 26, 5, 0, 10);
  final waits = <Duration>[];
  final reasons = <String>[];
  late final smart = KeyedSmartOtp(
    keys: keys,
    supported: () async => supported,
    unlock: (reason) async {
      reasons.add(reason);
      return allow;
    },
    clock: () => now,
    wait: (duration) async {
      waits.add(duration);
      now = now.add(duration);
    },
  );
  String expected(String secret, [int skip = 0]) =>
      totpCode(secret, totpStep(now) + skip);
}

void main() {
  group('totp', () {
    test('matches the RFC 6238 SHA-1 vectors (last six digits)', () {
      const vectors = {
        59: '287082',
        1111111109: '081804',
        1111111111: '050471',
        1234567890: '005924',
        2000000000: '279037',
        20000000000: '353130',
      };
      vectors.forEach((seconds, code) {
        final step = totpStep(
          DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
        );
        expect(totpCode(rfcSecret, step), code, reason: 'T=$seconds');
      });
    });

    test('base32 ignores case, spaces and padding; rejects bad input', () {
      expect(
        utf8.decode(base32Decode('gezd gnbv gy3t qojq====')),
        '1234567890',
      );
      expect(() => base32Decode(''), throwsFormatException);
      expect(() => base32Decode('ABC1'), throwsFormatException);
    });
  });

  group('KeyedSmartOtp', () {
    test('is never offered without platform support', () async {
      final h = Harness(supported: false);
      h.keys.values['nene.smart_otp.customer'] = rfcSecret;
      expect(await h.smart.available(), isFalse);
      expect(await h.smart.enabled('customer'), isFalse);
      expect(await h.smart.code('customer'), isNull);
      expect(await h.smart.adopt('customer', rfcSecret), isNull);
      expect(h.reasons, isEmpty);
    });

    test('adopt asks to unlock, saves the key and returns its code', () async {
      final h = Harness();
      expect(await h.smart.adopt('customer', rfcSecret), h.expected(rfcSecret));
      expect(h.reasons, ['Turn on Nene Smart OTP']);
      expect(await h.smart.enabled('customer'), isTrue);
      expect(await h.smart.enabled('someone-else'), isFalse);
    });

    test('a cancelled prompt saves nothing and gives no code', () async {
      final h = Harness(allow: false);
      expect(await h.smart.adopt('customer', rfcSecret), isNull);
      expect(h.keys.values, isEmpty);
      h.keys.values['nene.smart_otp.customer'] = rfcSecret;
      expect(await h.smart.code('customer'), isNull);
    });

    test('a malformed key is refused before any prompt', () async {
      final h = Harness();
      expect(await h.smart.adopt('customer', 'not base32!'), isNull);
      expect(h.reasons, isEmpty);
      expect(h.keys.values, isEmpty);
    });

    test('never offers the same time step twice; waits for the next', () async {
      final h = Harness();
      await h.smart.adopt('customer', rfcSecret);
      final first = totpStep(h.now), before = h.now;
      final second = await h.smart.code('customer');
      expect(h.waits, [totpStepStart(first + 1).difference(before)]);
      expect(h.waits.single, const Duration(seconds: 20));
      expect(second, totpCode(rfcSecret, first + 1));
      expect(h.reasons.last, 'Confirm with Nene Smart OTP');
    });

    test(
      'restore puts the previous key back; keep confirms the new one',
      () async {
        final h = Harness();
        h.keys.values['nene.smart_otp.customer'] = otherSecret;
        await h.smart.adopt('customer', rfcSecret);
        expect(h.keys.values['nene.smart_otp.customer'], rfcSecret);
        await h.smart.restore('customer');
        expect(h.keys.values['nene.smart_otp.customer'], otherSecret);

        await h.smart.adopt('customer', rfcSecret);
        await h.smart.keep('customer');
        await h.smart.restore('customer');
        expect(h.keys.values['nene.smart_otp.customer'], rfcSecret);
      },
    );

    test('restore after a first adopt removes the key', () async {
      final h = Harness();
      await h.smart.adopt('customer', rfcSecret);
      await h.smart.restore('customer');
      expect(h.keys.values, isEmpty);
    });

    test('remove deletes only that person\'s key', () async {
      final h = Harness();
      h.keys.values['nene.smart_otp.customer'] = rfcSecret;
      h.keys.values['nene.smart_otp.other'] = otherSecret;
      await h.smart.remove('customer');
      expect(h.keys.values.keys, ['nene.smart_otp.other']);
    });
  });

  group('screens', () {
    testWidgets('transfer: Smart OTP sends a generated code and posts', (
      tester,
    ) async {
      final h = Harness();
      h.keys.values['nene.smart_otp.customer'] = rfcSecret;
      String? sentCode;
      await confirmation.showScreen(
        tester,
        (req) async {
          if (req.url.path.endsWith('/configuration')) {
            return confirmation.json({'enabled': true});
          }
          if (req.url.path.endsWith('/transfers/')) {
            return confirmation.json({'transfers': <Map<String, dynamic>>[]});
          }
          if (req.url.path.endsWith('/security')) {
            return confirmation.json({'state': 'ready'});
          }
          if (req.url.path.endsWith('/review')) {
            return confirmation.json({
              ...confirmation.review(),
              'sufficientFunds': true,
              'executionAvailable': true,
            });
          }
          expect(req.url.path.endsWith('/transfers/confirm'), true);
          sentCode = jsonDecode(req.body)['code'] as String;
          return confirmation.json({
            'requestId': 'request',
            'revision': 2,
            'purpose': 'same-bank-transfer',
            'accessToken': 'test',
            'refreshToken': 'test',
            'state': 'posted',
            'sent': true,
            'executionAvailable': true,
            'replay': false,
          });
        },
        sendMoney: true,
        smartOtp: h.smart,
      );
      await confirmation.prepare(tester);
      await confirmation.tap(tester, 'Confirm with Smart OTP');
      expect(sentCode, h.expected(rfcSecret));
      expect(find.textContaining('Demo transfer sent.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('transfer: no Smart OTP button without a saved key', (
      tester,
    ) async {
      final h = Harness();
      await confirmation.showScreen(
        tester,
        (req) async {
          if (req.url.path.endsWith('/configuration')) {
            return confirmation.json({'enabled': true});
          }
          if (req.url.path.endsWith('/transfers/')) {
            return confirmation.json({'transfers': <Map<String, dynamic>>[]});
          }
          if (req.url.path.endsWith('/security')) {
            return confirmation.json({'state': 'ready'});
          }
          return confirmation.json({
            ...confirmation.review(),
            'sufficientFunds': true,
          });
        },
        sendMoney: true,
        smartOtp: h.smart,
      );
      await confirmation.prepare(tester);
      expect(find.text('Authenticator code'), findsOneWidget);
      expect(find.text('Confirm with Smart OTP'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    Future<SecurityApi> setupApi(
      WidgetTester tester,
      Harness h, {
      required int verifyStatus,
      List<String>? sent,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final owner = SessionOwner(Port());
      await owner.signIn('', '');
      addTearDown(owner.dispose);
      var ready = false;
      return SecurityApi(
        baseUrl: Uri.parse('http://localhost/api/v1/'),
        owner: owner,
        smartOtp: h.smart,
        client: MockClient((req) async {
          if (req.url.path.endsWith('/setup')) {
            return http.Response(
              jsonEncode({
                'requestId': 'setup',
                'revision': 1,
                'secret': rfcSecret,
              }),
              201,
            );
          }
          if (req.url.path.endsWith('/verify')) {
            sent?.add(jsonDecode(req.body)['code'] as String);
            if (verifyStatus != 201) return http.Response('{}', verifyStatus);
            ready = true;
            return http.Response(
              jsonEncode({
                'requestId': 'setup',
                'revision': 1,
                'accessToken': 'test',
                'refreshToken': 'test',
              }),
              201,
            );
          }
          return http.Response(
            jsonEncode({'state': ready ? 'ready' : 'not_set_up'}),
            200,
          );
        }),
      );
    }

    testWidgets('setup: Smart OTP links the key without typing a code', (
      tester,
    ) async {
      final h = Harness();
      final sent = <String>[];
      final api = await setupApi(tester, h, verifyStatus: 201, sent: sent);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SecurityScreen(api: api)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up authenticator'));
      await tester.pumpAndSettle();
      expect(find.text('Or link an authenticator app'), findsOneWidget);
      await tester.tap(find.text('Use Smart OTP on this phone'));
      await tester.pumpAndSettle();
      expect(sent, [h.expected(rfcSecret)]);
      expect(h.keys.values['nene.smart_otp.customer'], rfcSecret);
      expect(find.text('Authenticator ready'), findsOneWidget);
      expect(find.text('Smart OTP is on for this phone.'), findsOneWidget);
      expect(find.text(rfcSecret), findsNothing);

      await tester.ensureVisible(find.text('Turn off Smart OTP on this phone'));
      await tester.tap(find.text('Turn off Smart OTP on this phone'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn off'));
      await tester.pumpAndSettle();
      expect(h.keys.values, isEmpty);
      expect(find.textContaining('Smart OTP is off on this phone'), findsOne);
      expect(tester.takeException(), isNull);
    });

    testWidgets('setup: a rejected Smart OTP code removes the saved key', (
      tester,
    ) async {
      final h = Harness();
      final api = await setupApi(tester, h, verifyStatus: 400);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SecurityScreen(api: api)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up authenticator'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use Smart OTP on this phone'));
      await tester.pumpAndSettle();
      expect(h.keys.values, isEmpty);
      expect(find.textContaining('That code was not accepted'), findsOneWidget);
    });

    testWidgets('setup: web and desktop previews never offer Smart OTP', (
      tester,
    ) async {
      final h = Harness(supported: false);
      final api = await setupApi(tester, h, verifyStatus: 201);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SecurityScreen(api: api)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up authenticator'));
      await tester.pumpAndSettle();
      expect(find.text('Use Smart OTP on this phone'), findsNothing);
      expect(find.text('Link your authenticator'), findsOneWidget);
    });

    Future<http.Response> Function(http.Request) replacement(
      List<String> sent, {
      required int verifyStatus,
    }) {
      var step = 'authorized';
      return (req) async {
        if (req.url.path.endsWith('/management/enroll')) {
          step = 'pending';
          return management.json({'secret': rfcSecret});
        }
        if (req.url.path.endsWith('/management/verify')) {
          sent.add(jsonDecode(req.body)['code'] as String);
          if (verifyStatus != 200) return http.Response('{}', verifyStatus);
          step = 'verified';
          return management.json({
            'requestId': 'request',
            'revision': 2,
            'purpose': 'manage-new',
            'accessToken': 'test',
            'refreshToken': 'test',
          });
        }
        return management.json({
          'remaining': 10,
          'management': {
            ...management.management(step),
            'purpose': 'replace',
            'proofKind': step == 'verified'
                ? 'new_authenticator'
                : 'current_authenticator',
          },
        });
      };
    }

    testWidgets('replacement: Smart OTP takes over the new key', (
      tester,
    ) async {
      final h = Harness();
      h.keys.values['nene.smart_otp.customer'] = otherSecret;
      final sent = <String>[];
      await management.showScreen(
        tester,
        replacement(sent, verifyStatus: 200),
        smartOtp: h.smart,
      );
      await management.tap(tester, 'Set up replacement');
      // The old key must not fill a code for the new authenticator.
      expect(find.text('Fill with Smart OTP'), findsNothing);
      await management.tap(tester, 'Use Smart OTP on this phone');
      expect(sent, [h.expected(rfcSecret)]);
      expect(h.keys.values['nene.smart_otp.customer'], rfcSecret);
      // The next step asks for a new-authenticator code: Smart OTP can fill it.
      await management.tap(tester, 'Fill with Smart OTP');
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, h.expected(rfcSecret));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('replacement: a rejected Smart OTP code restores the old key', (
      tester,
    ) async {
      final h = Harness();
      h.keys.values['nene.smart_otp.customer'] = otherSecret;
      final sent = <String>[];
      await management.showScreen(
        tester,
        replacement(sent, verifyStatus: 400),
        smartOtp: h.smart,
      );
      await management.tap(tester, 'Set up replacement');
      await management.tap(tester, 'Use Smart OTP on this phone');
      expect(sent, hasLength(1));
      expect(h.keys.values['nene.smart_otp.customer'], otherSecret);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('replacement: a typed new code retires the old Smart OTP key', (
      tester,
    ) async {
      final h = Harness();
      h.keys.values['nene.smart_otp.customer'] = otherSecret;
      final sent = <String>[];
      await management.showScreen(
        tester,
        replacement(sent, verifyStatus: 200),
        smartOtp: h.smart,
      );
      await management.tap(tester, 'Set up replacement');
      await tester.enterText(find.byType(TextField), '123456');
      await management.tap(tester, 'Verify replacement');
      expect(sent, ['123456']);
      expect(h.keys.values, isEmpty);
      expect(find.text('Fill with Smart OTP'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
