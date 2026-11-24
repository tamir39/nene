// Isolated real-provider probe, not Flutter app integration. Its caller owns a
// disposable Auth fixture and sends credentials once through stdin. This file
// never reads app config, persists sessions, or prints provider/user details.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gotrue/gotrue.dart';
import 'package:http/http.dart' as http;

const _maximumBytes = 64 * 1024;

class _ProbeFailure implements Exception {
  const _ProbeFailure();
}

void _require(bool condition) {
  if (!condition) throw const _ProbeFailure();
}

Future<Uint8List> _boundedBytes(Stream<List<int>> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    _require(bytes.length + chunk.length <= _maximumBytes);
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

class _ProbeTransport extends http.BaseClient {
  _ProbeTransport(this.origin);

  final String origin;
  final _inner = http.Client();
  var userReads = 0;
  var refreshExchanges = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _require(request.url.origin == origin);
    if (request.method == 'GET' && request.url.path == '/user') {
      _require(request.url.query.isEmpty);
      userReads++;
    } else if (request.method == 'POST' && request.url.path == '/token') {
      _require(request.url.query == 'grant_type=refresh_token');
      refreshExchanges++;
    } else {
      throw const _ProbeFailure();
    }
    request.followRedirects = false;
    request.maxRedirects = 0;
    final response = await _inner
        .send(request)
        .timeout(const Duration(seconds: 10));
    final body = await _boundedBytes(response.stream)
        .timeout(const Duration(seconds: 10));
    return http.StreamedResponse(
      Stream.value(body),
      response.statusCode,
      contentLength: body.length,
      headers: response.headers,
      request: response.request,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

Future<void> main() async {
  var stage = 'read_input';
  GoTrueClient? auth;
  _ProbeTransport? transport;
  try {
    final raw = await _boundedBytes(stdin).timeout(const Duration(seconds: 5));
    final decoded = jsonDecode(utf8.decode(raw));
    _require(decoded is Map<String, dynamic>);
    final input = decoded as Map<String, dynamic>;
    const keys = {
      'authOrigin',
      'expectedUserId',
      'expectedSessionId',
      'accessToken',
      'refreshToken',
    };
    _require(input.keys.toSet().containsAll(keys));
    _require(input.length == keys.length);
    _require(
      input.values.every((value) => value is String && value.isNotEmpty),
    );
    final origin = Uri.parse(input['authOrigin'] as String);
    _require(
      origin.scheme == 'http' &&
          origin.host == '127.0.0.1' &&
          origin.port >= 3001 &&
          origin.port <= 3005 &&
          origin.userInfo.isEmpty &&
          origin.query.isEmpty &&
          origin.fragment.isEmpty &&
          (origin.path.isEmpty || origin.path == '/'),
    );
    final expectedUser = input['expectedUserId'] as String;
    final expectedSession = input['expectedSessionId'] as String;
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    _require(uuid.hasMatch(expectedUser) && uuid.hasMatch(expectedSession));
    final access = input['accessToken'] as String;
    final refresh = input['refreshToken'] as String;
    // This decoding is an expiry prefilter only. The real provider validates
    // the token via setSession/getClaims/getUser in the following steps.
    final claims = decodeJwt(access).payload;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _require(claims.exp != null && claims.exp! > now + 120);

    transport = _ProbeTransport(origin.origin);
    auth = GoTrueClient(
      url: origin.origin,
      autoRefreshToken: false,
      httpClient: transport,
    );
    stage = 'adopt_fresh_pair';
    final adopted = await auth.setSession(refresh, accessToken: access);
    _require(adopted.user?.id == expectedUser);
    _require(auth.currentSession?.accessToken == access);
    _require(auth.currentSession?.refreshToken == refresh);
    _require(transport.refreshExchanges == 0);

    stage = 'validate_adopted_subject_and_session';
    final verified = await auth.getClaims(access);
    final user = await auth.getUser(access);
    _require(verified.claims.sub == expectedUser);
    _require(verified.claims.claims['session_id'] == expectedSession);
    _require(verified.claims.claims['aal'] == 'aal2');
    _require(user.user?.id == expectedUser);
    _require(transport.refreshExchanges == 0);

    stage = 'refresh_adopted_pair';
    final refreshed = await auth.refreshSession();
    final next = refreshed.session;
    _require(next != null && next.user.id == expectedUser);
    _require(next!.refreshToken != null && next.refreshToken!.isNotEmpty);
    _require(next.refreshToken != refresh);
    _require(auth.currentSession?.accessToken == next.accessToken);
    _require(transport.refreshExchanges == 1);

    stage = 'validate_refreshed_subject_and_session';
    final refreshedClaims = await auth.getClaims(next.accessToken);
    final refreshedUser = await auth.getUser(next.accessToken);
    _require(refreshedClaims.claims.sub == expectedUser);
    _require(refreshedClaims.claims.claims['session_id'] == expectedSession);
    _require(refreshedClaims.claims.claims['aal'] == 'aal2');
    _require(refreshedUser.user?.id == expectedUser);

    stdout.writeln(
      jsonEncode({
        'result': 'passed',
        'probe': 'real_provider_dart_session_handoff',
        'freshAdoptionWithoutRefresh': true,
        'adoptedSubjectAndSessionMatch': true,
        'explicitRefreshSucceeded': true,
        'refreshTokenRotated': true,
        'refreshedSubjectAndSessionMatch': true,
        'aal': 'aal2',
        'userEndpointReads': transport.userReads,
        'refreshExchanges': transport.refreshExchanges,
        'persistentSessionStorage': false,
        'appIntegration': false,
      }),
    );
  } catch (_) {
    // SDK/provider failures may embed JWTs or identifiers. Deliberately omit the
    // exception, stack, response body and stdin from both output streams.
    stderr.writeln(
      jsonEncode({
        'result': 'failed',
        'probe': 'real_provider_dart_session_handoff',
        'stage': stage,
        'detail': 'Provider and input details suppressed.',
      }),
    );
    exitCode = 1;
  } finally {
    // Do not sign out: the parent owns the fixture and the updated session.
    // Disposing is local cleanup and does not revoke its provider session.
    auth?.dispose();
    transport?.close();
  }
}
