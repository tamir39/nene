import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nene_app/data/banking_repository.dart';
import 'package:nene_app/data/profile_api.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/session_controller.dart';

import 'test_doubles.dart';

Future<void> tapText(WidgetTester tester, String text) async {
  final target = find.text(text);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<SessionController> mountWorkspace(
  WidgetTester tester,
  FakeAuth auth,
  FakeBanking repository, {
  bool officer = false,
}) async {
  auth.userId = 'user-id';
  auth.accessToken = 'test-token';
  final profiles = FakeProfiles()
    ..fetch = (_) async => officer ? officerProfile : demoProfile;
  final session = SessionController(auth: auth, profiles: profiles);
  await tester.pumpWidget(NeneApp(controller: session, banking: repository));
  await tester.pumpAndSettle();
  return session;
}

Future<void> fillCreation(WidgetTester tester) async {
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), 'New Customer');
  await tester.enterText(fields.at(1), 'new@example.test');
  await tester.enterText(fields.at(2), '+84 12345');
  await tester.enterText(fields.at(3), 'Demo address');
  await tester.enterText(fields.at(4), 'synthetic-demo-password');
}

void main() {
  testWidgets('customer sees real account and can retry a failed contact save', (
    tester,
  ) async {
    final auth = FakeAuth();
    final repository = FakeBanking()
      ..contact = (_, _) async =>
          throw const ApiException(ApiFailure.unavailable);
    await mountWorkspace(tester, auth, repository);
    expect(find.text('0 VND'), findsOneWidget);
    expect(find.text('100000000001'), findsOneWidget);
    expect(find.text('Create customer'), findsNothing);
    expect(find.text('Find a customer'), findsNothing);
    await tapText(tester, 'Edit contact details');
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '+84 99999');
    await tester.enterText(fields.at(1), 'Updated demo address');
    await tapText(tester, 'Save contact details');
    expect(
      find.text(
        'Unable to save your contact details. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('+84 99999'), findsOneWidget);
    repository.contact = FakeBanking().contact;
    await tapText(tester, 'Save contact details');
    expect(find.text('Contact details saved.'), findsOneWidget);
    expect(find.text('Updated demo address'), findsOneWidget);
    expect(repository.contactCalls, 2);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });

  testWidgets('empty and failed account reads never invent a balance', (
    tester,
  ) async {
    final auth = FakeAuth();
    final repository = FakeBanking()
      ..accounts = (_) async =>
          throw const ApiException(ApiFailure.unavailable);
    await mountWorkspace(tester, auth, repository);
    expect(find.text('0 VND'), findsNothing);
    expect(find.text('Retry accounts'), findsOneWidget);
    repository.accounts = (_) async => [];
    await tapText(tester, 'Retry accounts');
    expect(
      find.text('No accounts are linked yet. Your bank officer can help.'),
      findsOneWidget,
    );
    expect(find.text('0 VND'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });

  testWidgets(
    'officer creates with review, retries exact request and clears form',
    (tester) async {
      final auth = FakeAuth();
      final repository = FakeBanking()
        ..create = (_, _) async =>
            throw const ApiException(ApiFailure.unavailable);
      await mountWorkspace(tester, auth, repository, officer: true);
      expect(find.text('Edit contact details'), findsNothing);
      expect(repository.accountsCalls, 0);
      await tapText(tester, 'Create customer');
      await fillCreation(tester);
      final password = tester.widget<TextFormField>(
        find.byType(TextFormField).at(4),
      );
      expect(password.controller?.text, 'synthetic-demo-password');
      expect(
        tester.widget<EditableText>(find.byType(EditableText).last).obscureText,
        isTrue,
      );
      await tapText(tester, 'Review customer');
      expect(repository.createCalls, 0);
      expect(find.text('synthetic-demo-password'), findsNothing);
      await tapText(tester, 'Confirm and create');
      expect(repository.createCalls, 1);
      expect(find.text('Retry same request'), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing);
      repository.create = (_, _) async => demoCustomer;
      await tapText(tester, 'Retry same request');
      expect(repository.creationKeys[0], repository.creationKeys[1]);
      expect(repository.creationDrafts[0], same(repository.creationDrafts[1]));
      expect(find.text('Customer details'), findsOneWidget);
      expect(find.text('0 VND'), findsOneWidget);
      expect(find.text('synthetic-demo-password'), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Create customer');
      for (final field in tester.widgetList<TextFormField>(
        find.byType(TextFormField),
      )) {
        expect(field.controller?.text, isEmpty);
      }
      await tester.pumpWidget(const SizedBox());
      await auth.events.close();
    },
  );

  testWidgets('ordinary background/resume preserves uncertain creation retry', (
    tester,
  ) async {
    final auth = FakeAuth();
    final repository = FakeBanking()
      ..create = (_, _) async =>
          throw const ApiException(ApiFailure.unavailable);
    await mountWorkspace(tester, auth, repository, officer: true);
    await tapText(tester, 'Create customer');
    await fillCreation(tester);
    await tapText(tester, 'Review customer');
    await tapText(tester, 'Confirm and create');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Retry same request'), findsOneWidget);
    repository.create = (_, _) async => demoCustomer;
    await tapText(tester, 'Retry same request');
    expect(repository.creationKeys[0], repository.creationKeys[1]);
    expect(repository.creationDrafts[0], same(repository.creationDrafts[1]));
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });

  testWidgets(
    'sign-out removes a pending protected screen and ignores its result',
    (tester) async {
      final auth = FakeAuth();
      final repository = FakeBanking();
      final pending = Completer<CustomerDetail>();
      repository.create = (_, _) => pending.future;
      await mountWorkspace(tester, auth, repository, officer: true);
      await tapText(tester, 'Create customer');
      await fillCreation(tester);
      await tapText(tester, 'Review customer');
      await tester.ensureVisible(find.text('Confirm and create'));
      await tester.tap(find.text('Confirm and create'));
      await tester.pump();
      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();
      pending.complete(demoCustomer);
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.text('Customer details'), findsNothing);
      expect(find.text('New Customer'), findsNothing);
      expect(find.text('synthetic-demo-password'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('New Customer'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await auth.events.close();
    },
  );

  testWidgets('officer searches and records a customer-requested change', (
    tester,
  ) async {
    final auth = FakeAuth();
    final repository = FakeBanking();
    String? reasonSent;
    repository.update = (name, phone, address, reason) async {
      reasonSent = reason;
      return CustomerDetail(
        id: demoCustomer.id,
        email: demoCustomer.email,
        displayName: name,
        phone: phone,
        address: address,
        accounts: demoCustomer.accounts,
      );
    };
    await mountWorkspace(tester, auth, repository, officer: true);
    await tapText(tester, 'Find a customer');
    await tester.enterText(find.byType(TextField), 'new@example.test');
    await tapText(tester, 'Search customers');
    await tapText(tester, 'View customer');
    await tapText(tester, 'Make a requested change');
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(4));
    await tester.enterText(fields.at(0), 'Corrected Customer');
    await tester.enterText(fields.at(1), '');
    await tester.enterText(fields.at(3), 'Customer requested name correction');
    await tapText(tester, 'Save requested changes');
    expect(reasonSent, 'Customer requested name correction');
    expect(find.text('Corrected Customer'), findsOneWidget);
    expect(find.text('Requested changes saved.'), findsOneWidget);
    expect(find.text('new@example.test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });

  testWidgets(
    'creation is usable on small phone with 200 percent text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetViewInsets);
      final auth = FakeAuth();
      final repository = FakeBanking();
      await mountWorkspace(tester, auth, repository, officer: true);
      await tapText(tester, 'Create customer');
      await fillCreation(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tapText(tester, 'Review customer');
      expect(tester.takeException(), isNull);
      await tapText(tester, 'Confirm and create');
      expect(repository.createCalls, 1);
      expect(find.text('Customer details'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await auth.events.close();
    },
  );
}
