import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/savings_policy_api.dart';
import 'package:nene_app/session_controller.dart';
import 'package:nene_app/ui/savings_policy_screen.dart';
import 'test_doubles.dart';

void main() {
  testWidgets(
    'officer saves exact basis points and must reload after a conflict',
    (tester) async {
      final auth = FakeAuth()
        ..userId = officerProfile.id
        ..accessToken = 'test-token';
      final profiles = FakeProfiles()..fetch = (_) async => officerProfile;
      final session = SessionController(auth: auth, profiles: profiles);
      await session.loadProfile();
      addTearDown(session.dispose);
      var saves = 0;
      final api = SavingsPolicyApi(
        baseUrl: Uri.parse('http://localhost/api/v1/'),
        client: MockClient((req) async {
          if (req.method == 'PATCH') {
            saves++;
            final data = jsonDecode(req.body) as Map<String, dynamic>;
            expect(data['annualRateBps'], 625);
            expect(data['reason'], 'Annual policy review');
            if (saves == 2) return http.Response('{}', 409);
            expect(data['revision'], 1);
            return http.Response('{"annualRateBps":625,"revision":2}', 200);
          }
          return http.Response('{"annualRateBps":600,"revision":1}', 200);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SavingsPolicyScreen(session: session, api: api),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '6.25');
      await tester.enterText(
        find.byType(TextField).at(1),
        'Annual policy review',
      );
      await tester.tap(find.text('Save savings rate'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Savings rate saved'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).at(1),
        'Annual policy review',
      );
      await tester.tap(find.text('Save savings rate'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Reload the current rate'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
