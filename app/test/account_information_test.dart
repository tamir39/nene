import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nene_app/data/banking_repository.dart';
import 'package:nene_app/ui/customer_workspace.dart';
import 'package:nene_app/ui/nene_brand.dart';

import 'customer_workspace_test.dart' show mountWorkspace, tapText;
import 'test_doubles.dart';

Future<void> _pumpCard(
  WidgetTester tester,
  BankAccount account, {
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: neneTheme(),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: SingleChildScrollView(child: AccountCard(account)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String option) async {
  await tester.ensureVisible(find.text(option));
  await tester.tap(find.text(option));
  await tester.pumpAndSettle();
}

void main() {
  final base = <String, dynamic>{
    'id': 'test',
    'accountNumber': '100',
    'type': 'saving',
    'currency': 'VND',
    'balanceMinor': '10000000',
    'status': 'active',
  };
  final mortgage = <String, dynamic>{
    ...base,
    'type': 'mortgage',
    'balanceMinor': '0',
    'monthlyDueMinor': '4250000',
    'biweeklyDueMinor': '1961539',
    'principalRemainingMinor': '51000000',
    'nextDueOn': '2026-12-01',
    'isDemo': true,
  };
  final older = Map<String, dynamic>.of(mortgage)..remove('biweeklyDueMinor');
  final toggle = find.byType(SegmentedButton<bool>);

  test('two-week amount is optional and validated like other amounts', () {
    expect(BankAccount.fromJson(mortgage).biweeklyDueMinor, '1961539');
    final account = BankAccount.fromJson(older);
    expect(account.biweeklyDueMinor, isNull);
    expect(account.monthlyDueMinor, '4250000');
    for (final value in [1961539, '1.5', '-1']) {
      expect(
        () => BankAccount.fromJson({...mortgage, 'biweeklyDueMinor': value}),
        throwsFormatException,
      );
    }
  });

  testWidgets('mortgage card defaults to monthly and toggles to two weeks', (
    tester,
  ) async {
    await _pumpCard(tester, BankAccount.fromJson(mortgage));
    expect(tester.widget<SegmentedButton<bool>>(toggle).selected, {false});
    expect(find.text('Monthly repayment'), findsOneWidget);
    expect(find.text('4,250,000 VND'), findsOneWidget);
    expect(find.text('Repayment every 2 weeks'), findsNothing);
    expect(find.text('1,961,539 VND'), findsNothing);
    expect(find.textContaining('26 payments'), findsNothing);

    await _choose(tester, 'Every 2 weeks');
    expect(tester.widget<SegmentedButton<bool>>(toggle).selected, {true});
    expect(find.text('Repayment every 2 weeks'), findsOneWidget);
    expect(find.text('1,961,539 VND'), findsOneWidget);
    expect(find.text('Monthly repayment'), findsNothing);
    expect(find.text('4,250,000 VND'), findsNothing);
    expect(
      find.text(
        'Equivalent of the monthly schedule: the same yearly total '
        'over 26 payments, rounded up.',
      ),
      findsOneWidget,
    );
    expect(find.text('Next due: 2026-12-01'), findsOneWidget);
    expect(
      find.text('Synthetic demo · 0% sample schedule · no loan issued'),
      findsOneWidget,
    );

    await _choose(tester, 'Monthly');
    expect(find.text('Monthly repayment'), findsOneWidget);
    expect(find.text('4,250,000 VND'), findsOneWidget);
    expect(find.textContaining('26 payments'), findsNothing);
  });

  testWidgets('older responses and missing schedules show no toggle', (
    tester,
  ) async {
    await _pumpCard(tester, BankAccount.fromJson(older));
    expect(toggle, findsNothing);
    expect(find.text('Monthly repayment'), findsOneWidget);
    expect(find.text('4,250,000 VND'), findsOneWidget);

    await _pumpCard(
      tester,
      BankAccount.fromJson({
        ...mortgage,
        'monthlyDueMinor': null,
        'biweeklyDueMinor': null,
      }),
    );
    expect(toggle, findsNothing);
    expect(find.text('Repayment schedule unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggle fits a 320 px screen at 200 percent text', (
    tester,
  ) async {
    await _pumpCard(
      tester,
      BankAccount.fromJson(mortgage),
      width: 320,
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('4,250,000 VND'), findsOneWidget);
    await _choose(tester, 'Every 2 weeks');
    expect(tester.takeException(), isNull);
    expect(find.text('Repayment every 2 weeks'), findsOneWidget);
    expect(find.text('1,961,539 VND'), findsOneWidget);
    await _choose(tester, 'Monthly');
    expect(tester.takeException(), isNull);
    expect(find.text('4,250,000 VND'), findsOneWidget);
  });

  testWidgets('officer customer details offer the same two-week view', (
    tester,
  ) async {
    final auth = FakeAuth();
    final repository = FakeBanking()
      ..detail = (_) async => CustomerDetail(
        id: demoCustomer.id,
        email: demoCustomer.email,
        displayName: demoCustomer.displayName,
        accounts: [BankAccount.fromJson(mortgage)],
      );
    await mountWorkspace(tester, auth, repository, officer: true);
    await tapText(tester, 'Find a customer');
    await tester.enterText(find.byType(TextField), 'new@example.test');
    await tapText(tester, 'Search customers');
    await tapText(tester, 'View customer');
    expect(find.text('4,250,000 VND'), findsOneWidget);
    await _choose(tester, 'Every 2 weeks');
    expect(find.text('Repayment every 2 weeks'), findsOneWidget);
    expect(find.text('1,961,539 VND'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });
  test(
    'savings information retains integer amounts and rejects malformed values',
    () {
      final account = BankAccount.fromJson({
        ...base,
        'annualRateBps': 600,
        'monthlyProfitMinor': '50000',
      });
      expect(account.annualRateBps, 600);
      expect(account.monthlyProfitMinor, '50000');
      expect(account.isDemo, false);
      expect(
        () => BankAccount.fromJson({...base, 'isDemo': 'true'}),
        throwsFormatException,
      );
      expect(
        () => BankAccount.fromJson({...base, 'monthlyProfitMinor': 1.5}),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'saving and mortgage cards show distinct information without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final account in [
        BankAccount.fromJson({
          ...base,
          'annualRateBps': 600,
          'monthlyProfitMinor': '50000',
          'isDemo': true,
        }),
        BankAccount.fromJson({
          ...base,
          'type': 'mortgage',
          'balanceMinor': '0',
          'monthlyDueMinor': '500000',
          'principalRemainingMinor': '5000000',
          'nextDueOn': '2026-12-01',
          'isDemo': true,
        }),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: SingleChildScrollView(child: AccountCard(account)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (account.type == 'saving') {
          expect(find.text('Annual rate: 6.00%'), findsOneWidget);
          expect(
            find.text('Synthetic demo account · no money deposited'),
            findsOneWidget,
          );
          expect(find.textContaining('50,000 VND'), findsOneWidget);
        } else {
          expect(find.text('Monthly repayment'), findsOneWidget);
          expect(
            find.text('Synthetic demo · 0% sample schedule · no loan issued'),
            findsOneWidget,
          );
          expect(find.text('Next due: 2026-12-01'), findsOneWidget);
        }
      }
    },
  );
}
