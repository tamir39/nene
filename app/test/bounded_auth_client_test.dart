import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nene_app/data/bounded_auth_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Transport extends http.BaseClient {
  _Transport(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);

  @override
  void close() => closeCount++;
}

http.StreamedResponse _response(Map<String, Object> body) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, Object> _session(String id) => {
  'access_token': '$id-access-token',
  'refresh_token': '$id-refresh-token',
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': {
    'id': id,
    'aud': 'authenticated',
    'email': '$id@example.test',
    'created_at': '2026-10-17T00:00:00Z',
  },
};

void main() {
  test(
    'forwards the Auth request and closes transport after the body',
    () async {
      final transport = _Transport((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), 'https://example.test/auth/v1/token');
        expect(request.headers['apikey'], 'public-key');
        expect(await request.finalize().bytesToString(), '{"email":"demo"}');
        return _response({'ok': true});
      });
      final client = BoundedAuthClient(createClient: () => transport);
      addTearDown(client.close);

      final response = await client.post(
        Uri.parse('https://example.test/auth/v1/token'),
        headers: {'apikey': 'public-key'},
        body: '{"email":"demo"}',
      );

      expect(response.statusCode, 200);
      expect(jsonDecode(response.body), {'ok': true});
      expect(transport.closeCount, 1);
    },
  );

  test('bounds a stalled response body as well as the headers', () async {
    final body = StreamController<List<int>>();
    final transport = _Transport(
      (_) async => http.StreamedResponse(body.stream, 200),
    );
    final client = BoundedAuthClient(
      timeout: const Duration(milliseconds: 10),
      createClient: () => transport,
    );
    addTearDown(client.close);

    await expectLater(
      client.get(Uri.parse('https://example.test/auth/v1/user')),
      throwsA(isA<http.ClientException>()),
    );
    expect(transport.closeCount, 1);
    // A non-cooperative test transport can still finish later. Its response
    // is consumed only by the already-failed transport future, never the SDK.
    body.add(utf8.encode('{}'));
    await body.close();
  });

  test(
    'late timed-out login cannot install a session or replace a retry',
    () async {
      final lateResponse = Completer<http.StreamedResponse>();
      final oldTransport = _Transport((_) => lateResponse.future);
      final retryTransport = _Transport(
        (_) async => _response(_session('new')),
      );
      var requestCount = 0;
      final client = BoundedAuthClient(
        timeout: const Duration(milliseconds: 10),
        createClient: () => requestCount++ == 0 ? oldTransport : retryTransport,
      );
      final auth = GoTrueClient(
        url: 'https://example.test/auth/v1',
        autoRefreshToken: false,
        httpClient: client,
      );
      addTearDown(() {
        auth.dispose();
        client.close();
      });

      await expectLater(
        auth.signInWithPassword(
          email: 'old@example.test',
          password: 'synthetic',
        ),
        throwsA(isA<AuthException>()),
      );
      expect(auth.currentSession, isNull);
      expect(oldTransport.closeCount, 1);

      await auth.signInWithPassword(
        email: 'new@example.test',
        password: 'synthetic',
      );
      expect(auth.currentUser?.id, 'new');

      lateResponse.complete(_response(_session('old')));
      await Future<void>.delayed(Duration.zero);
      expect(auth.currentUser?.id, 'new');
      expect(auth.currentSession?.accessToken, 'new-access-token');
      expect(retryTransport.closeCount, 1);
    },
  );

  test('closing the Auth client rejects further requests', () async {
    final client = BoundedAuthClient(
      createClient: () => throw StateError('Must not start a transport'),
    );
    client.close();
    await expectLater(
      client.get(Uri.parse('https://example.test/auth/v1/user')),
      throwsA(isA<http.ClientException>()),
    );
  });
}
