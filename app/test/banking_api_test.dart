import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/banking_api.dart';
import 'package:nene_app/data/banking_repository.dart';
import 'package:nene_app/data/profile_api.dart';

Map<String, Object?> accountJson({Object? balance = '0'}) => {
  'id': 'account-id',
  'accountNumber': '100000000001',
  'type': 'checking',
  'currency': 'VND',
  'balanceMinor': balance,
  'status': 'active',
};

Map<String, Object?> customerJson() => {
  'id': 'customer-id',
  'email': 'new@example.test',
  'displayName': 'New Customer',
  'phone': null,
  'address': null,
  'accounts': [accountJson()],
};

const creationDraft = CustomerDraft(
  email: 'new@example.test',
  displayName: 'New Customer',
  phone: null,
  address: null,
  initialPassword: 'synthetic-demo-password',
);

void main() {
  BankingApi api(http.Client client) => BankingApi(
    baseUrl: Uri.parse('https://api.example.test/api/v1/'),
    client: client,
  );

  test('account read uses NestJS and preserves integer precision', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/me/accounts');
      expect(request.headers['Authorization'], 'Bearer token');
      expect(request.followRedirects, isFalse);
      return http.Response(
        jsonEncode({
          'accounts': [accountJson(balance: '9007199254740993')],
        }),
        200,
      );
    });
    final result = await api(client).getAccounts('token');
    expect(result.single.balanceMinor, '9007199254740993');
    expect(result.single.balanceLabel, '9,007,199,254,740,993 VND');
  });

  test(
    'missing or non-string balances fail rather than displaying zero',
    () async {
      for (final value in [null, 0, '0.5', 'unknown']) {
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'accounts': [accountJson(balance: value)],
            }),
            200,
          ),
        );
        await expectLater(
          api(client).getAccounts('token'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.failure,
              'failure',
              ApiFailure.invalidResponse,
            ),
          ),
        );
      }
    },
  );

  test('contact edit sends only nullable contact fields', () async {
    final client = MockClient((request) async {
      expect(request.method, 'PATCH');
      expect(request.url.path, '/api/v1/me/contact');
      expect(jsonDecode(request.body), {'phone': '+84 12345', 'address': null});
      return http.Response(
        jsonEncode({
          ...customerJson(),
          'role': 'customer',
          'phone': '+84 12345',
        }),
        200,
      );
    });
    final result = await api(
      client,
    ).updateContact('token', phone: '+84 12345', address: null);
    expect(result.phone, '+84 12345');
    expect(result.address, isNull);
  });

  test(
    'creation body has no financial/role fields and sends request UUID',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/officer/customers');
        expect(request.url.query, isEmpty);
        expect(request.followRedirects, isFalse);
        expect(
          request.headers['Idempotency-Key'],
          '11111111-1111-4111-8111-111111111111',
        );
        expect(jsonDecode(request.body), creationDraft.toJson());
        return http.Response(jsonEncode(customerJson()), 201);
      });
      final result = await api(client).createCustomer(
        'token',
        creationDraft,
        '11111111-1111-4111-8111-111111111111',
      );
      expect(result.accounts.single.balanceLabel, '0 VND');
    },
  );

  test('search encodes query and requested edit excludes email', () async {
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        expect(request.url.queryParameters, {'query': 'a+b@example.test'});
        return http.Response(
          jsonEncode({
            'customers': [customerJson()],
          }),
          200,
        );
      }
      expect(request.url.path, '/api/v1/officer/customers/customer-id');
      expect(jsonDecode(request.body), {
        'displayName': 'Updated Name',
        'phone': null,
        'address': 'New address',
        'requestReason': 'Customer requested address correction',
      });
      return http.Response(
        jsonEncode({...customerJson(), 'displayName': 'Updated Name'}),
        200,
      );
    });
    final repository = api(client);
    expect(
      (await repository.findCustomers('token', 'a+b@example.test')).length,
      1,
    );
    expect(
      (await repository.updateCustomer(
        'token',
        'customer-id',
        displayName: 'Updated Name',
        phone: null,
        address: 'New address',
        requestReason: 'Customer requested address correction',
      )).displayName,
      'Updated Name',
    );
  });

  test('errors are classified without carrying raw provider text', () async {
    for (final entry in {
      400: ApiFailure.invalidInput,
      401: ApiFailure.unauthorized,
      403: ApiFailure.forbidden,
      404: ApiFailure.notFound,
      409: ApiFailure.conflict,
      503: ApiFailure.unavailable,
      302: ApiFailure.unavailable,
    }.entries) {
      final client = MockClient(
        (_) async => http.Response('private provider diagnostic', entry.key),
      );
      await expectLater(
        api(client).getAccounts('token'),
        throwsA(
          isA<ApiException>().having((e) => e.failure, 'failure', entry.value),
        ),
      );
    }
  });

  test('empty session cannot make a banking request', () async {
    final client = MockClient((_) async => throw StateError('Must not send'));
    await expectLater(
      api(client).getAccounts(''),
      throwsA(
        isA<ApiException>().having(
          (e) => e.failure,
          'failure',
          ApiFailure.unauthorized,
        ),
      ),
    );
  });

  test(
    'only the allowlisted duplicate code makes a conflict correctable',
    () async {
      for (final code in ['CUSTOMER_EMAIL_EXISTS', 'UNKNOWN_CONFLICT']) {
        final client = MockClient(
          (_) async => http.Response(jsonEncode({'code': code}), 409),
        );
        await expectLater(
          api(client).createCustomer(
            'token',
            creationDraft,
            '11111111-1111-4111-8111-111111111111',
          ),
          throwsA(
            isA<ApiException>().having(
              (e) => e.failure,
              'failure',
              code == 'CUSTOMER_EMAIL_EXISTS'
                  ? ApiFailure.customerExists
                  : ApiFailure.conflict,
            ),
          ),
        );
      }
    },
  );
}
