// Renders review screenshots of the money-movement flow (transfer, other-bank,
// cash, preview) and account history with the bundled Be Vietnam Pro font.
// Skipped in ordinary runs; generate with:
//   flutter test test/ui_capture_money_test.dart --dart-define=CAPTURE_UI=true
// Images are written to the ignored ../.tmp/ui-review/ folder.
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
import 'package:nene_app/data/confirmation_api.dart';
import 'package:nene_app/data/security_api.dart';
import 'package:nene_app/data/session_owner.dart';
import 'package:nene_app/data/user_profile.dart';
import 'package:nene_app/nene_app.dart';
import 'package:nene_app/session_controller.dart';
import 'package:nene_app/ui/confirmation_screen.dart';
import 'package:nene_app/ui/nene_brand.dart';

import 'confirmation_screen_test.dart' as transfer show json, tap;
import 'interbank_transfer_test.dart'
    as interbank
    show configuration, review, posted, select;
import 'security_screen_test.dart' show Port;
import 'test_doubles.dart';

const _capture = bool.fromEnvironment('CAPTURE_UI');
final _base = Uri.parse('http://localhost/api/v1/');
final _offline = MockClient((_) async => http.Response('{}', 404));
const _key = ValueKey('ui-capture');
const _requestId = '7f3c9a12-5b1e-4d0a-9c2b-1e8f6a4d3b90';

const _an = UserProfile(
  id: 'user-id',
  email: 'an@example.invalid',
  displayName: 'Nguyễn Văn An',
  role: AppRole.customer,
);
const _checking = BankAccount(
  id: 'checking',
  accountNumber: '100000000001',
  type: 'checking',
  currency: 'VND',
  balanceMinor: '3000000',
  status: 'active',
);

typedef _Handler = Future<http.Response> Function(http.Request);

Future<void> _fonts(WidgetTester tester) async {
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '../.tools/flutter';
  Future<ByteData> bytes(String path) =>
      File(path).readAsBytes().then(ByteData.sublistView);
  await tester.runAsync(() async {
    final family = FontLoader('BeVietnamPro');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      family.addFont(bytes('assets/fonts/BeVietnamPro-$weight.ttf'));
    }
    await family.load();
    await (FontLoader('MaterialIcons')..addFont(
          bytes(
            '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ))
        .load();
  });
}

Future<SessionOwner> _view(WidgetTester tester, double height) async {
  tester.view.physicalSize = Size(390, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await _fonts(tester);
  final credentials = SessionOwner(Port());
  await credentials.signIn('', '');
  addTearDown(credentials.dispose);
  return credentials;
}

/// The real workspace, so captures include its app bar and back control.
Future<void> _mountApp(
  WidgetTester tester, {
  double height = 844,
  _Handler? security,
  _Handler? history,
}) async {
  final credentials = await _view(tester, height);
  final session = SessionController(
    auth: FakeAuth()
      ..userId = _an.id
      ..accessToken = 'test-token',
    profiles: FakeProfiles()..fetch = (_) async => _an,
  );
  await session.loadProfile();
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: NeneApp(
        controller: session,
        banking: FakeBanking()..accounts = (_) async => const [_checking],
        security: SecurityApi(
          baseUrl: _base,
          owner: credentials,
          client: security == null ? _offline : MockClient(security),
        ),
        history: AccountHistoryApi(
          baseUrl: _base,
          client: history == null ? _offline : MockClient(history),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The preview ("not sent") mode has no home entry point, so it is mounted
/// directly under an app bar matching the workspace.
Future<void> _mountPreview(WidgetTester tester, _Handler handler) async {
  final credentials = await _view(tester, 1200);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: neneTheme(),
        home: Scaffold(
          appBar: AppBar(
            leading: const Icon(Icons.arrow_back),
            title: const NeneLogo(size: 30),
          ),
          body: ConfirmationScreen(
            account: _checking,
            api: ConfirmationApi(
              SecurityApi(
                baseUrl: _base,
                owner: credentials,
                client: MockClient(handler),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _shoot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_key));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../.tmp/ui-review/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
  expect(tester.takeException(), isNull);
}

Map<String, dynamic> _review(Map<String, dynamic> extra) => {
  'reviewToken': 'synthetic-review',
  'requestId': _requestId,
  'revision': 2,
  'sourceAccountNumber': _checking.accountNumber,
  'destinationAccountNumber': '100000000002',
  'amountMinor': '150000',
  'currency': 'VND',
  'feeMinor': '0',
  'expiresAt': DateTime.now()
      .add(const Duration(minutes: 10))
      .toIso8601String(),
  'sufficientFunds': true,
  'executionAvailable': true,
  ...extra,
};

Map<String, dynamic> _confirmed(String purpose, {bool sent = true}) => {
  'requestId': _requestId,
  'revision': 2,
  'purpose': purpose,
  'accessToken': 'test',
  'refreshToken': 'test',
  'state': sent ? 'posted' : 'factor_confirmed',
  'sent': sent,
  'executionAvailable': sent,
  'replay': false,
};

/// Same-bank transfers; [confirmStatus] replaces the confirm response.
_Handler _transfers({bool enabled = true, int? confirmStatus}) => (req) async {
  final path = req.url.path;
  if (path.endsWith('/security')) return transfer.json({'state': 'ready'});
  if (path.endsWith('/configuration')) {
    return transfer.json({'enabled': enabled});
  }
  if (path.endsWith('/transfers/')) {
    return transfer.json({
      'transfers': enabled
          ? [
              {
                'requestId': '4b8e2f6a-91c3-4d7e-b5a0-2c6f8e1d9a37',
                'state': 'posted',
                'receipt': {'amountMinor': '250000'},
              },
              {
                'requestId': '9d1a7c3e-2f4b-4e8a-a6c5-7b3e0f9d2c18',
                'state': 'expired',
              },
            ]
          : <Map<String, dynamic>>[],
    });
  }
  if (path.endsWith('/review')) return transfer.json(_review({}));
  if (path.endsWith('/confirm')) {
    return confirmStatus == null
        ? transfer.json(_confirmed('same-bank-transfer'))
        : http.Response('{}', confirmStatus);
  }
  return transfer.json({
    'state': 'rejected',
    'sent': false,
    'executionAvailable': false,
  });
};

_Handler _interbank() => (req) async {
  final path = req.url.path;
  final receipt = {...interbank.posted(replay: true), 'requestId': _requestId};
  if (path.endsWith('/security')) return transfer.json({'state': 'ready'});
  if (path.endsWith('/configuration')) {
    return transfer.json(interbank.configuration());
  }
  if (path.endsWith('/interbank-transfers/')) {
    return transfer.json({
      'transfers': [receipt],
    });
  }
  if (path.endsWith('/review')) return transfer.json(interbank.review());
  return transfer.json(receipt);
};

_Handler _cash(CashOperation operation) => (req) async {
  final path = req.url.path;
  if (path.endsWith('/security')) return transfer.json({'state': 'ready'});
  if (path.endsWith('/configuration')) {
    return transfer.json({'enabled': true, 'cashBalanceMinor': '3000000'});
  }
  if (path.endsWith('/${operation.name}/')) {
    return transfer.json({'operations': <Map<String, dynamic>>[]});
  }
  if (path.endsWith('/review')) {
    return transfer.json(
      _review({
        'accountNumber': _checking.accountNumber,
        'operation': operation.name,
        'amountMinor': '500000',
      }),
    );
  }
  return transfer.json(_confirmed('cash-${operation.name}'));
};

_Handler _preview() => (req) async {
  final path = req.url.path;
  if (path.endsWith('/security')) return transfer.json({'state': 'ready'});
  if (path.endsWith('/review')) {
    return transfer.json(
      _review({'sufficientFunds': false, 'executionAvailable': false}),
    );
  }
  return transfer.json(_confirmed('transaction-confirmation', sent: false));
};

Map<String, dynamic> _entry(int i) {
  const kinds = [
    'transfer',
    'deposit',
    'interbank_transfer',
    'withdrawal',
    'interest',
    'payment',
    'transfer',
  ];
  const amounts = [
    '150000',
    '2000000',
    '450000',
    '300000',
    '12500',
    '89000',
    '1200000',
  ];
  final kind = kinds[i % kinds.length];
  final credit =
      kind == 'deposit' || kind == 'interest' || (kind == 'transfer' && i > 0);
  return {
    'id': 'entry-$i',
    'reference':
        'b7c1e4a2-0f3d-4e9b-9a6c-${(i + 1).toString().padLeft(12, '0')}',
    'kind': kind,
    'direction': credit ? 'credit' : 'debit',
    'amountMinor': amounts[i % amounts.length],
    'currency': 'VND',
    'postedAt': DateTime.utc(
      2026,
      11,
      24 - i ~/ 2,
      9 - i % 3,
      15 + i,
    ).toIso8601String(),
  };
}

_Handler _history(List<Map<String, dynamic>>? rows) => (req) async {
  if (rows == null) return http.Response('{}', 503);
  return http.Response(
    jsonEncode({
      'accountId': req.url.pathSegments[4],
      'month': req.url.queryParameters['month'],
      'timeZone': 'Asia/Bangkok',
      'entries': rows,
      'nextCursor': rows.length == 25 ? rows.last['id'] : null,
    }),
    200,
  );
};

Future<void> _scrollToTop(WidgetTester tester) async {
  await tester.drag(
    find.byType(SingleChildScrollView).first,
    const Offset(0, 5000),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('capture same-bank transfer flow', (tester) async {
    if (!_capture) return;
    await _mountApp(tester, height: 1240, security: _transfers());
    await transfer.tap(tester, 'Transfer');
    await tester.enterText(find.byType(TextField).at(0), '100000000002');
    await tester.enterText(find.byType(TextField).at(1), '150000');
    FocusManager.instance.primaryFocus?.unfocus();
    await _shoot(tester, 'money-transfer-form');
    await transfer.tap(tester, 'Review confirmation');
    await _scrollToTop(tester);
    await tester.enterText(find.byType(TextField), '123456');
    FocusManager.instance.primaryFocus?.unfocus();
    await _shoot(tester, 'money-transfer-review');
    await transfer.tap(tester, 'Confirm and send demo funds');
    await _scrollToTop(tester);
    await _shoot(tester, 'money-transfer-receipt');
  });

  testWidgets('capture unconfirmed transfer outcome', (tester) async {
    if (!_capture) return;
    await _mountApp(
      tester,
      height: 1100,
      security: _transfers(confirmStatus: 503),
    );
    await transfer.tap(tester, 'Transfer');
    await tester.enterText(find.byType(TextField).at(0), '100000000002');
    await tester.enterText(find.byType(TextField).at(1), '150000');
    await transfer.tap(tester, 'Review confirmation');
    await tester.enterText(find.byType(TextField), '123456');
    await transfer.tap(tester, 'Confirm and send demo funds');
    await _scrollToTop(tester);
    await _shoot(tester, 'money-transfer-unknown');
  });

  testWidgets('capture rejected transfer code', (tester) async {
    if (!_capture) return;
    await _mountApp(
      tester,
      height: 1100,
      security: _transfers(confirmStatus: 400),
    );
    await transfer.tap(tester, 'Transfer');
    await tester.enterText(find.byType(TextField).at(0), '100000000002');
    await tester.enterText(find.byType(TextField).at(1), '150000');
    await transfer.tap(tester, 'Review confirmation');
    await tester.enterText(find.byType(TextField), '123456');
    await transfer.tap(tester, 'Confirm and send demo funds');
    await transfer.tap(tester, 'Check confirmation status');
    await _scrollToTop(tester);
    await _shoot(tester, 'money-transfer-rejected');
  });

  testWidgets('capture disabled transfer demo', (tester) async {
    if (!_capture) return;
    await _mountApp(tester, height: 1100, security: _transfers(enabled: false));
    await transfer.tap(tester, 'Transfer');
    await _shoot(tester, 'money-transfer-disabled');
  });

  testWidgets('capture other-bank transfer', (tester) async {
    if (!_capture) return;
    await _mountApp(tester, height: 1240, security: _interbank());
    await transfer.tap(tester, 'Other bank');
    await interbank.select(
      tester,
      'Demo Bank A',
      'Demo recipient A · 990000000001',
    );
    await tester.enterText(find.byType(TextField), '100000');
    FocusManager.instance.primaryFocus?.unfocus();
    await _shoot(tester, 'money-interbank-form');
    await transfer.tap(tester, 'Review confirmation');
    await _scrollToTop(tester);
    await _shoot(tester, 'money-interbank-review');
    await transfer.tap(tester, 'Edit details / new review');
    await transfer.tap(tester, 'Simulated 100,000 VND · demo funds');
    await _scrollToTop(tester);
    await _shoot(tester, 'money-interbank-receipt');
  });

  for (final operation in CashOperation.values) {
    testWidgets('capture ${operation.name} flow', (tester) async {
      if (!_capture) return;
      await _mountApp(tester, height: 1100, security: _cash(operation));
      await transfer.tap(
        tester,
        operation == CashOperation.deposit ? 'Deposit' : 'Withdraw',
      );
      await tester.enterText(find.byType(TextField), '500000');
      FocusManager.instance.primaryFocus?.unfocus();
      await _shoot(tester, 'money-${operation.name}-form');
      await transfer.tap(tester, 'Review confirmation');
      await tester.enterText(find.byType(TextField), '123456');
      await transfer.tap(
        tester,
        operation == CashOperation.deposit
            ? 'Confirm demo deposit'
            : 'Confirm demo withdrawal',
      );
      await _scrollToTop(tester);
      await _shoot(tester, 'money-${operation.name}-receipt');
    });
  }

  testWidgets('capture preview confirmation (not sent)', (tester) async {
    if (!_capture) return;
    await _mountPreview(tester, _preview());
    await tester.enterText(find.byType(TextField).at(0), '100000000002');
    await tester.enterText(find.byType(TextField).at(1), '150000');
    await transfer.tap(tester, 'Review confirmation');
    await _scrollToTop(tester);
    await _shoot(tester, 'money-preview-review');
    await tester.enterText(find.byType(TextField), '123456');
    await transfer.tap(tester, 'Check authenticator · do not send');
    await _scrollToTop(tester);
    await _shoot(tester, 'money-preview-result');
  });

  testWidgets('capture account history', (tester) async {
    if (!_capture) return;
    await _mountApp(tester, history: _history(List.generate(25, _entry)));
    await transfer.tap(tester, 'History');
    await _shoot(tester, 'money-history');
    await tester.ensureVisible(find.text('Load more'));
    await _shoot(tester, 'money-history-end');
  });

  testWidgets('capture empty account history', (tester) async {
    if (!_capture) return;
    await _mountApp(tester, history: _history([]));
    await transfer.tap(tester, 'History');
    await _shoot(tester, 'money-history-empty');
  });

  testWidgets('capture failed account history', (tester) async {
    if (!_capture) return;
    await _mountApp(tester, history: _history(null));
    await transfer.tap(tester, 'History');
    await _shoot(tester, 'money-history-error');
  });
}
