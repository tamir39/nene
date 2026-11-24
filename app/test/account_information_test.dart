import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nene_app/data/banking_repository.dart';
import 'package:nene_app/ui/customer_workspace.dart';

void main() {
  final base = <String, dynamic>{
    'id': 'test',
    'accountNumber': '100',
    'type': 'saving',
    'currency': 'VND',
    'balanceMinor': '10000000',
    'status': 'active',
  };
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
