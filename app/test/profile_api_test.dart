import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/profile_api.dart';
import 'package:nene_app/data/user_profile.dart';

Map<String, Object> profileJson({String role = 'customer'}) => {
  'id': 'user-id',
  'email': 'student@example.test',
  'displayName': 'Demo Student',
  'role': role,
};

void main() {
  ProfileApi api(http.Client client) => ProfileApi(
    baseUrl: Uri.parse('https://api.example.test/api/v1/'),
    client: client,
  );

  test(
    'sends the bearer token only to the versioned API without redirects',
    () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://api.example.test/api/v1/me');
        expect(request.headers['Authorization'], 'Bearer session-token');
        expect(request.followRedirects, isFalse);
        expect(request.url.query, isEmpty);
        return http.Response(jsonEncode(profileJson()), 200);
      });
      final profile = await api(client).getProfile('session-token');
      expect(profile.role, AppRole.customer);
    },
  );

  test('does not send unauthenticated requests', () async {
    final client = MockClient(
      (_) async => throw StateError('Must not be called'),
    );
    await expectLater(
      api(client).getProfile(''),
      throwsA(
        isA<ApiException>().having(
          (e) => e.failure,
          'failure',
          ApiFailure.unauthorized,
        ),
      ),
    );
  });

  test('accepts nullable email from the backend profile contract', () async {
    final data = <String, Object?>{...profileJson(), 'email': null};
    final client = MockClient(
      (_) async => http.Response(jsonEncode(data), 200),
    );
    expect((await api(client).getProfile('token')).email, isNull);
  });

  test('maps API errors without exposing raw backend response data', () async {
    for (final entry in {
      401: ApiFailure.unauthorized,
      403: ApiFailure.forbidden,
      500: ApiFailure.unavailable,
      302: ApiFailure.unavailable,
    }.entries) {
      final client = MockClient(
        (_) async => http.Response('sensitive detail', entry.key),
      );
      await expectLater(
        api(client).getProfile('token'),
        throwsA(
          isA<ApiException>().having((e) => e.failure, 'failure', entry.value),
        ),
      );
    }
  });

  test('fails closed for unrecognized roles and malformed profiles', () async {
    for (final data in [
      profileJson(role: 'admin'),
      {'id': 'user-id'},
      ['unexpected'],
    ]) {
      final client = MockClient(
        (_) async => http.Response(jsonEncode(data), 200),
      );
      await expectLater(
        api(client).getProfile('token'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.failure,
            'failure',
            ApiFailure.invalidResponse,
          ),
        ),
      );
    }
  });

  test('handles network failure as unavailable', () async {
    final client = MockClient(
      (_) async => throw http.ClientException('offline'),
    );
    await expectLater(
      api(client).getProfile('token'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.failure,
          'failure',
          ApiFailure.unavailable,
        ),
      ),
    );
  });
}
