// Isolated stateless Supabase Auth adapter. It creates no GoTrueClient, stores
// no session and uses no browser storage/broadcast or background refresh timer.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'session_owner.dart';

class SupabaseAuthPort implements AuthPort {
  SupabaseAuthPort({
    required Uri authOrigin,
    required http.Client client,
    String? publishableKey,
  }) : _origin = authOrigin,
       _client = client,
       _publishableKey = publishableKey {
    // This candidate intentionally cannot be pointed at a hosted service. A
    // future app integration must preserve the existing release/TLS policy.
    if (authOrigin.scheme != 'http' ||
        authOrigin.host != '127.0.0.1' ||
        authOrigin.port < 3001 ||
        authOrigin.port > 3005 ||
        authOrigin.userInfo.isNotEmpty ||
        authOrigin.query.isNotEmpty ||
        authOrigin.fragment.isNotEmpty ||
        (authOrigin.path.isNotEmpty && authOrigin.path != '/')) {
      throw ArgumentError('Expected isolated Auth fixture origin.');
    }
  }

  final Uri _origin;
  final http.Client _client;
  final String? _publishableKey;

  Future<Map<String, dynamic>> _request(
    String path, {
    String method = 'GET',
    String? accessToken,
    Map<String, String>? body,
  }) async {
    try {
      final elapsed = Stopwatch()..start();
      Duration remaining() => const Duration(seconds: 10) - elapsed.elapsed;
      final request = http.Request(method, _origin.resolve(path))
        ..followRedirects = false
        ..maxRedirects = 0;
      request.headers['content-type'] = 'application/json';
      if (_publishableKey != null) request.headers['apikey'] = _publishableKey;
      if (accessToken != null) {
        request.headers['authorization'] = 'Bearer $accessToken';
      }
      if (body != null) request.body = jsonEncode(body);
      final response = await _client.send(request).timeout(remaining());
      final bytes = <int>[];
      final chunks = StreamIterator(response.stream);
      try {
        while (await chunks.moveNext().timeout(remaining())) {
          final chunk = chunks.current;
          if (bytes.length + chunk.length > 64 * 1024) {
            throw const SessionCoordinationException();
          }
          bytes.addAll(chunk);
        }
      } finally {
        await chunks.cancel();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const SessionCoordinationException();
      }
      if (bytes.isEmpty) return {};
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const SessionCoordinationException();
      }
      return decoded;
    } catch (_) {
      // Provider responses, passwords and tokens must not enter error logs.
      throw const SessionCoordinationException();
    }
  }

  AuthPair _pair(Map<String, dynamic> data) {
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    if (access is! String ||
        refresh is! String ||
        access.isEmpty ||
        refresh.isEmpty ||
        data['token_type'] != 'bearer') {
      throw const SessionCoordinationException();
    }
    return AuthPair(accessToken: access, refreshToken: refresh);
  }

  @override
  Future<AuthPair> signIn(String email, String password) async => _pair(
    await _request(
      '/token?grant_type=password',
      method: 'POST',
      body: {'email': email, 'password': password},
    ),
  );

  @override
  Future<AuthPair> refresh(OwnedSession session) async => _pair(
    await _request(
      '/token?grant_type=refresh_token',
      method: 'POST',
      body: {'refresh_token': session.pair.refreshToken},
    ),
  );

  @override
  Future<OwnedSession> validate(AuthPair pair) async {
    // Auth validates this exact token's signature, expiry and live session.
    // Decode claims only AFTER the same token succeeds at the trusted endpoint.
    // The opaque refresh token's matching provenance comes from the trusted
    // provider/backend reply; /user cannot authenticate that token or pair it.
    final user = await _request('/user', accessToken: pair.accessToken);
    try {
      final pieces = pair.accessToken.split('.');
      if (pieces.length != 3) throw const SessionCoordinationException();
      final decoded = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(pieces[1]))),
      );
      if (decoded is! Map<String, dynamic>) {
        throw const SessionCoordinationException();
      }
      final sub = decoded['sub'];
      final sessionId = decoded['session_id'];
      final exp = decoded['exp'];
      final uuid = RegExp(
        r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$',
        caseSensitive: false,
      );
      if (sub is! String ||
          sessionId is! String ||
          exp is! int ||
          !uuid.hasMatch(sub) ||
          !uuid.hasMatch(sessionId) ||
          sub != user['id'] ||
          decoded['iss'] != _origin.origin ||
          decoded['aud'] != 'authenticated') {
        throw const SessionCoordinationException();
      }
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        exp * 1000,
        isUtc: true,
      );
      if (!expiresAt.isAfter(DateTime.now())) {
        throw const SessionCoordinationException();
      }
      return OwnedSession(
        pair: pair,
        userId: sub,
        sessionId: sessionId,
        expiresAt: expiresAt,
      );
    } catch (_) {
      throw const SessionCoordinationException();
    }
  }

  @override
  Future<void> signOut(OwnedSession session) async {
    await _request(
      '/logout?scope=local',
      method: 'POST',
      accessToken: session.pair.accessToken,
    );
  }
}
