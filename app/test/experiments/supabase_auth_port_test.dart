import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../../experiments/session_coordinator/session_owner.dart';
import '../../../experiments/session_coordinator/supabase_auth_port.dart';

// Controlled HTTP boundary tests, not proof of a real provider signature check.
// A fake /user success represents the trusted provider's access-token verdict.
const userId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const otherUserId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const sessionId = '11111111-1111-4111-8111-111111111111';
final origin = Uri.parse('http://127.0.0.1:3001');

Map<String, dynamic> claims() => {
  'sub': userId,
  'session_id': sessionId,
  'exp':
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000,
  'iss': origin.origin,
  'aud': 'authenticated',
};

String token(Map<String, dynamic> payload) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(payload)}.${part('synthetic-only')}';
}

AuthPair pair({String refreshToken = 'synthetic-refresh'}) =>
    AuthPair(accessToken: token(claims()), refreshToken: refreshToken);

OwnedSession owned(AuthPair pair) => OwnedSession(
  pair: pair,
  userId: userId,
  sessionId: sessionId,
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
);

http.StreamedResponse response(
  Object? data, {
  int status = 200,
  Map<String, String>? headers,
}) => http.StreamedResponse(
  Stream.value(data == null ? <int>[] : utf8.encode(jsonEncode(data))),
  status,
  headers: headers ?? const {'content-type': 'application/json'},
);

Map<String, dynamic> grant(AuthPair pair) => {
  'access_token': pair.accessToken,
  'refresh_token': pair.refreshToken,
  'token_type': 'bearer',
};

class ControlledClient extends http.BaseClient {
  ControlledClient(this.reply);
  final Future<http.StreamedResponse> Function(http.Request) reply;
  final requests = <http.Request>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final typed = request as http.Request;
    requests.add(typed);
    return reply(typed);
  }
}

Future<void> rejects(Future<Object?> result) async {
  await expectLater(result, throwsA(isA<SessionCoordinationException>()));
}

void main() {
  test('only the bounded loopback fixture origin is accepted', () {
    final client = ControlledClient((_) async => response(null));
    for (final address in ['http://127.0.0.1:3001', 'http://127.0.0.1:3005/']) {
      expect(
        () => SupabaseAuthPort(authOrigin: Uri.parse(address), client: client),
        returnsNormally,
      );
    }
    for (final address in [
      'https://127.0.0.1:3001',
      'https://example.invalid',
      'http://localhost:3001',
      'http://192.168.1.2:3001',
      'http://[::1]:3001',
      'http://127.0.0.1:3000',
      'http://127.0.0.1:3006',
      'http://127.0.0.1',
      'http://user:secret@127.0.0.1:3001',
      'http://127.0.0.1:3001/auth/v1',
      'http://127.0.0.1:3001/?key=secret',
      'http://127.0.0.1:3001/#fragment',
    ]) {
      expect(
        () => SupabaseAuthPort(authOrigin: Uri.parse(address), client: client),
        throwsArgumentError,
        reason: address,
      );
    }
    expect(client.requests, isEmpty);
  });

  test(
    'password grant sends explicit credentials with redirects disabled',
    () async {
      final expected = pair();
      final client = ControlledClient((_) async => response(grant(expected)));
      final port = SupabaseAuthPort(
        authOrigin: origin,
        client: client,
        publishableKey: 'synthetic-publishable-key',
      );
      final received = await port.signIn(
        'synthetic@example.invalid',
        'synthetic-password',
      );
      expect(received.accessToken, expected.accessToken);
      expect(received.refreshToken, expected.refreshToken);
      final request = client.requests.single;
      expect(request.method, 'POST');
      expect(request.url, origin.resolve('/token?grant_type=password'));
      expect(jsonDecode(request.body), {
        'email': 'synthetic@example.invalid',
        'password': 'synthetic-password',
      });
      expect(request.headers['apikey'], 'synthetic-publishable-key');
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
    },
  );

  test(
    'refresh uses only the supplied session and never the last grant',
    () async {
      final login = pair(refreshToken: 'synthetic-login');
      final explicit = pair(refreshToken: 'synthetic-explicit');
      final client = ControlledClient((_) async => response(grant(login)));
      final port = SupabaseAuthPort(authOrigin: origin, client: client);
      await port.signIn('synthetic@example.invalid', 'synthetic-password');
      await port.refresh(owned(explicit));
      final request = client.requests.last;
      expect(request.url, origin.resolve('/token?grant_type=refresh_token'));
      expect(request.method, 'POST');
      expect(jsonDecode(request.body), {'refresh_token': 'synthetic-explicit'});
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.headers.containsKey('apikey'), isFalse);
    },
  );

  test(
    'validation authenticates the exact access token before adopting claims',
    () async {
      final supplied = pair();
      final client = ControlledClient((_) async => response({'id': userId}));
      final port = SupabaseAuthPort(authOrigin: origin, client: client);
      final verified = await port.validate(supplied);
      final request = client.requests.single;
      expect(request.method, 'GET');
      expect(request.url, origin.resolve('/user'));
      expect(
        request.headers['authorization'],
        'Bearer ${supplied.accessToken}',
      );
      expect(request.body, isEmpty);
      expect(verified.pair, same(supplied));
      expect(verified.userId, userId);
      expect(verified.sessionId, sessionId);
      expect(verified.expiresAt.isAfter(DateTime.now()), isTrue);
    },
  );

  test(
    'access validation cannot establish opaque refresh-token provenance',
    () async {
      final supplied = pair(refreshToken: 'synthetic-unrelated-opaque-token');
      final client = ControlledClient((_) async => response({'id': userId}));
      final port = SupabaseAuthPort(authOrigin: origin, client: client);
      final verified = await port.validate(supplied);
      // /user has no refresh-token pairing check. The caller must obtain the pair
      // from a trusted grant or authenticated handoff response, never a broadcast.
      expect(verified.pair.refreshToken, 'synthetic-unrelated-opaque-token');
      expect(client.requests.single.body, isEmpty);
      expect(client.requests.single.url.query, isEmpty);
    },
  );

  test(
    'trusted endpoint denial rejects plausible unverified token claims',
    () async {
      final client = ControlledClient(
        (_) async => response({'error': 'synthetic-secret'}, status: 401),
      );
      final port = SupabaseAuthPort(authOrigin: origin, client: client);
      await rejects(port.validate(pair()));
      expect(client.requests, hasLength(1));
    },
  );

  test('trusted user ID must match the validated access subject', () async {
    final client = ControlledClient((_) async => response({'id': otherUserId}));
    final port = SupabaseAuthPort(authOrigin: origin, client: client);
    await rejects(port.validate(pair()));
  });

  for (final entry in <String, Map<String, dynamic>>{
    'issuer': {'iss': 'https://other-provider.invalid'},
    'audience': {'aud': 'anon'},
    'missing session': {'session_id': null},
    'malformed session': {'session_id': 'not-a-session-uuid'},
    'malformed subject': {'sub': 'not-a-user-uuid'},
    'expired token': {'exp': 1},
    'noninteger expiry': {'exp': '9999999999'},
  }.entries) {
    test('validated access claims reject ${entry.key}', () async {
      final payload = {...claims(), ...entry.value};
      final client = ControlledClient(
        (_) async => response({'id': payload['sub']}),
      );
      final port = SupabaseAuthPort(authOrigin: origin, client: client);
      await rejects(
        port.validate(
          AuthPair(accessToken: token(payload), refreshToken: 'synthetic'),
        ),
      );
    });
  }

  test(
    'malformed access encoding is rejected after provider validation',
    () async {
      final client = ControlledClient((_) async => response({'id': userId}));
      final port = SupabaseAuthPort(authOrigin: origin, client: client);
      for (final access in [
        'not-a-jwt',
        'header.!.signature',
        'header.W10.signature',
      ]) {
        await rejects(
          port.validate(
            AuthPair(accessToken: access, refreshToken: 'synthetic'),
          ),
        );
      }
      expect(client.requests, hasLength(3));
    },
  );

  test(
    'logout targets only the explicit captured session with local scope',
    () async {
      final captured = pair();
      final client = ControlledClient((_) async => response(null, status: 204));
      final port = SupabaseAuthPort(authOrigin: origin, client: client);
      await port.signOut(owned(captured));
      final request = client.requests.single;
      expect(request.method, 'POST');
      expect(request.url, origin.resolve('/logout?scope=local'));
      expect(
        request.headers['authorization'],
        'Bearer ${captured.accessToken}',
      );
      expect(request.body, isEmpty);
      expect(request.followRedirects, isFalse);
    },
  );

  test(
    'grant responses require nonempty access and refresh tokens of bearer type',
    () async {
      for (final malformed in <Map<String, dynamic>>[
        {},
        {...grant(pair()), 'access_token': ''},
        {...grant(pair()), 'refresh_token': ''},
        {...grant(pair()), 'access_token': 123},
        {...grant(pair()), 'refresh_token': null},
        {...grant(pair()), 'token_type': 'basic'},
      ]) {
        final client = ControlledClient((_) async => response(malformed));
        final port = SupabaseAuthPort(authOrigin: origin, client: client);
        await rejects(port.signIn('synthetic', 'synthetic'));
      }
    },
  );

  test(
    'malformed JSON, non-object JSON and invalid UTF-8 fail with opaque errors',
    () async {
      for (final bytes in [
        utf8.encode('{'),
        utf8.encode('[]'),
        <int>[0xff],
      ]) {
        final client = ControlledClient(
          (_) async => http.StreamedResponse(Stream.value(bytes), 200),
        );
        final port = SupabaseAuthPort(authOrigin: origin, client: client);
        await rejects(port.signIn('synthetic', 'synthetic'));
      }
    },
  );

  test('response accumulation stops and cancels above 64 KiB', () async {
    var cancelled = false;
    var consumedThirdChunk = false;
    Stream<List<int>> oversized() async* {
      try {
        yield List.filled(64 * 1024, 32);
        yield [32];
        consumedThirdChunk = true;
        yield [32];
      } finally {
        cancelled = true;
      }
    }

    final client = ControlledClient(
      (_) async => http.StreamedResponse(oversized(), 200),
    );
    final port = SupabaseAuthPort(authOrigin: origin, client: client);
    await rejects(port.signIn('synthetic', 'synthetic'));
    expect(cancelled, isTrue);
    expect(consumedThirdChunk, isFalse);
  });

  test('redirects never dispatch credentials to a second target', () async {
    final client = ControlledClient(
      (_) async => response(
        null,
        status: 302,
        headers: {'location': 'https://other-provider.invalid/collect'},
      ),
    );
    final port = SupabaseAuthPort(authOrigin: origin, client: client);
    await rejects(port.signIn('synthetic', 'synthetic-password'));
    final request = client.requests.single;
    expect(request.url.origin, origin.origin);
    expect(request.followRedirects, isFalse);
    expect(request.maxRedirects, 0);
  });

  test(
    'transport and provider error bodies never escape in thrown messages',
    () async {
      for (final reply
          in <Future<http.StreamedResponse> Function(http.Request)>[
            (_) async => throw StateError('synthetic-secret-transport-detail'),
            (_) async => response({
              'message': 'synthetic-secret-provider-detail',
            }, status: 500),
          ]) {
        final client = ControlledClient(reply);
        final port = SupabaseAuthPort(authOrigin: origin, client: client);
        try {
          await port.signIn('synthetic', 'synthetic-secret-password');
          fail('Expected a controlled error');
        } catch (error) {
          expect(error, isA<SessionCoordinationException>());
          expect(error.toString(), isNot(contains('synthetic-secret')));
        }
      }
    },
  );

  test('trickled response bytes cannot extend the total deadline', () async {
    var cancelled = false;
    final chunks = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    final client = ControlledClient(
      (_) async => http.StreamedResponse(chunks.stream, 200),
    );
    final port = SupabaseAuthPort(authOrigin: origin, client: client);
    final elapsed = Stopwatch()..start();
    final result = rejects(port.signIn('synthetic', 'synthetic'));
    await Future<void>.delayed(const Duration(seconds: 6));
    chunks.add(utf8.encode('{'));
    await result;
    // This uses elapsed wall time because the adapter intentionally uses a
    // monotonic Stopwatch, independent of Flutter's fake animation clock.
    expect(elapsed.elapsed, lessThan(const Duration(seconds: 14)));
    expect(cancelled, isTrue);
    await chunks.close();
  });

  testWidgets('a stalled request fails at the fixed transport deadline', (
    tester,
  ) async {
    final never = Completer<http.StreamedResponse>();
    final client = ControlledClient((_) => never.future);
    final port = SupabaseAuthPort(authOrigin: origin, client: client);
    final result = rejects(port.signIn('synthetic', 'synthetic'));
    await tester.pump(const Duration(seconds: 11));
    await result;
  });
}
