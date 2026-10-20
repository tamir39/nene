import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nene_app/data/user_profile.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/session_controller.dart';

import 'test_doubles.dart';

void main() {
  testWidgets('unconfigured build has no sign-in or fake banking controls', (
    tester,
  ) async {
    await tester.pumpWidget(const NeneApp());
    expect(find.text('Nene is unavailable'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets('sign-in validates inputs before contacting authentication', (
    tester,
  ) async {
    final auth = FakeAuth();
    final controller = SessionController(auth: auth, profiles: FakeProfiles());
    await tester.pumpWidget(
      NeneApp(controller: controller, banking: FakeBanking()),
    );
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(auth.signInCount, 0);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });

  testWidgets('officer view comes from API profile and sign-out clears it', (
    tester,
  ) async {
    final auth = FakeAuth();
    final profiles = FakeProfiles()
      ..fetch = (_) async => const UserProfile(
        id: 'user-id',
        email: 'officer@example.test',
        displayName: 'Demo Officer',
        role: AppRole.officer,
      );
    final controller = SessionController(auth: auth, profiles: profiles);
    await tester.pumpWidget(
      NeneApp(controller: controller, banking: FakeBanking()),
    );
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'officer@example.test',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'test-password');
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Officer workspace'), findsOneWidget);
    expect(find.text('Demo Officer'), findsOneWidget);
    await tester.tap(find.byTooltip('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Demo Officer'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });

  testWidgets(
    'large text and keyboard keep sign-in reachable on a small phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetViewInsets);
      final auth = FakeAuth()..signInError = StateError('Unavailable');
      final controller = SessionController(
        auth: auth,
        profiles: FakeProfiles(),
      );
      await tester.pumpWidget(
        NeneApp(controller: controller, banking: FakeBanking()),
      );
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'demo@example.test',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'test-password');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Sign in'));
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(auth.signInCount, 1);
      expect(
        find.text('Unable to sign in. Check your details and connection.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await auth.events.close();
    },
  );

  testWidgets('customer profile remains truthful at large text size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final auth = FakeAuth()
      ..userId = 'user-id'
      ..accessToken = 'test-token';
    final controller = SessionController(auth: auth, profiles: FakeProfiles());
    await tester.pumpWidget(
      NeneApp(controller: controller, banking: FakeBanking()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Demo Student'), findsOneWidget);
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Officer workspace'), findsNothing);
    expect(
      find.text(
        'Identity verification is not completed in this demo. '
        'Deposits, withdrawals, transfers and payments are not available.',
      ),
      findsOneWidget,
    );
    expect(find.text('Transfer'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Demo Student'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });
}
