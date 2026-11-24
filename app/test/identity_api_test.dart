import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nene_app/data/identity_api.dart';
import 'package:nene_app/data/profile_api.dart';

import 'identity_test_doubles.dart';

void main() {
  IdentityApi api(http.Client client) => IdentityApi(
    baseUrl: Uri.parse('https://api.example.test/api/v1/'),
    client: client,
  );
  test(
    'identity reads and uploads use authenticated NestJS paths with exact contract',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        expect(request.headers['Authorization'], 'Bearer token');
        expect(request.followRedirects, isFalse);
        return http.Response(jsonEncode(identityJson()), 200);
      });
      final service = api(client);
      await service.getSummary('token');
      expect(requests.last.url.path, '/api/v1/me/identity');
      await service.getSummary('token', customerId: 'customer-id');
      expect(
        requests.last.url.path,
        '/api/v1/officer/customers/customer-id/identity',
      );
      await service.upload(
        'token',
        'case-id',
        version: 4,
        contentType: 'image/png',
        bytes: referenceFixture,
        key: 'retry-key',
      );
      expect(requests.last.url.path, '/api/v1/identity/cases/case-id/evidence');
      expect(requests.last.headers['Idempotency-Key'], 'retry-key');
      expect(jsonDecode(requests.last.body), {
        'expectedVersion': 4,
        'contentType': 'image/png',
        'dataBase64': base64Encode(referenceFixture),
      });
      await service.review(
        'token',
        'case-id',
        version: 5,
        action: 'accept_reference',
        associationConfirmed: true,
        key: 'review-key',
      );
      expect(
        requests.last.url.path,
        '/api/v1/officer/identity/cases/case-id/reviews',
      );
      expect(jsonDecode(requests.last.body), {
        'expectedVersion': 5,
        'action': 'accept_reference',
        'associationConfirmed': true,
        'reason': null,
      });
    },
  );
  test(
    'private preview requires authenticated image response and no redirects',
    () async {
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer token');
        expect(
          request.url.path,
          '/api/v1/identity/cases/case-id/evidence/evidence-id',
        );
        expect(request.followRedirects, isFalse);
        return http.Response.bytes(
          referenceFixture,
          200,
          headers: {'content-type': 'image/png'},
        );
      });
      expect(
        await api(client).getEvidence('token', 'case-id', 'evidence-id'),
        referenceFixture,
      );
      final html = MockClient(
        (_) async => http.Response(
          '<html>Error</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        api(html).getEvidence('token', 'c', 'e'),
        throwsA(isA<ApiException>()),
      );
    },
  );
  test(
    'invalid states, missing customer and HTTP failures fail closed',
    () async {
      for (final bad in [
        <String, dynamic>{},
        {...identityJson(), 'status': 'verified'},
      ]) {
        await expectLater(
          api(
            MockClient((_) async => http.Response(jsonEncode(bad), 200)),
          ).getSummary('token'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.failure,
              'failure',
              ApiFailure.invalidResponse,
            ),
          ),
        );
      }
      for (final entry in {
        401: ApiFailure.unauthorized,
        403: ApiFailure.forbidden,
        404: ApiFailure.notFound,
        409: ApiFailure.conflict,
        413: ApiFailure.invalidInput,
        503: ApiFailure.unavailable,
      }.entries) {
        await expectLater(
          api(
            MockClient((_) async => http.Response('{}', entry.key)),
          ).getSummary('token'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.failure,
              'failure',
              entry.value,
            ),
          ),
        );
      }
    },
  );
}
