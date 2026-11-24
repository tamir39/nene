import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/ui/security_screen.dart';

class Port implements AuthPort {
  @override
  Future<AuthPair> signIn(String e, String p) async =>
      const AuthPair(accessToken: 'test', refreshToken: 'test');
  @override
  Future<OwnedSession> validate(AuthPair pair) async => OwnedSession(
    pair: pair,
    userId: 'customer',
    sessionId: 'session',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );
  @override
  Future<AuthPair> refresh(OwnedSession session) async => session.pair;
  @override
  Future<void> signOut(OwnedSession session) async {}
}

void main() {
  testWidgets(
    'manual setup renders on a narrow screen, verifies and clears the secret',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final owner = SessionOwner(Port());
      await owner.signIn('', '');
      addTearDown(owner.dispose);
      var ready = false;
      final api = SecurityApi(
        baseUrl: Uri.parse('http://localhost/api/v1/'),
        owner: owner,
        client: MockClient((req) async {
          expect(req.headers['authorization'], 'Bearer test');
          if (req.url.path.endsWith('/setup')) {
            return http.Response(
              jsonEncode({
                'requestId': 'setup',
                'revision': 1,
                'secret': 'SYNTHETICKEY',
              }),
              201,
            );
          }
          if (req.url.path.endsWith('/verify')) {
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SecurityScreen(api: api)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up authenticator'));
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETICKEY'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '123456');
      await tester.ensureVisible(find.text('Verify setup'));
      await tester.tap(find.text('Verify setup'));
      await tester.pumpAndSettle();
      expect(find.text('Authenticator ready'), findsOneWidget);
      expect(find.text('SYNTHETICKEY'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'definite rejection retains the owner and permits a corrected proof',
    () async {
      final owner = SessionOwner(Port());
      await owner.signIn('', '');
      addTearDown(owner.dispose);
      const binding = HandoffBinding(
        requestId: 'request',
        purpose: 'enroll',
        securityRevision: 1,
      );
      await expectLater(
        owner.exchange(
          binding,
          (_) async => throw const SessionMutationRejected(),
        ),
        throwsA(isA<SessionMutationRejected>()),
      );
      expect(owner.session, isNotNull);
      await owner.exchange(
        binding,
        (s) async => HandoffReply(pair: s.pair, binding: binding),
      );
    },
  );
}
