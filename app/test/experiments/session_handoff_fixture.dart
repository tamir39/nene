// Test-only handoff candidate. This is not imported by app/lib and is not a
// production Auth repository. Real GoTrue methods run against fake HTTP replies.
// In particular, the fixture does not prove provider signature verification,
// refresh-token validity/revocation, or browser BroadcastChannel isolation.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const probeUserA = '10000000-0000-4000-8000-000000000001';
const probeUserB = '10000000-0000-4000-8000-000000000002';
const probeSessionA = '20000000-0000-4000-8000-000000000001';
const probeSessionB = '20000000-0000-4000-8000-000000000002';

Map<String, dynamic> probeUser(String id) => {
  'id': id,
  'aud': 'authenticated',
  'email': '$id@example.invalid',
  'created_at': '2026-10-27T00:00:00Z',
  'app_metadata': <String, dynamic>{},
  'user_metadata': <String, dynamic>{},
};

String probeToken({
  String userId = probeUserA,
  String sessionId = probeSessionA,
  String label = 'initial',
  int remainingSeconds = 3600,
}) {
  String encode(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': userId, 'session_id': sessionId, 'aud': 'authenticated', 'iss': 'https://auth-probe.invalid/auth/v1', 'iat': now, 'exp': now + remainingSeconds, 'jti': label, 'aal': 'aal2'})}.c3ludGhldGljLXNpZ25hdHVyZQ';
}

Map<String, dynamic> probeSession(
  String token, {
  String userId = probeUserA,
  String refresh = 'synthetic-initial-refresh',
}) => {
  'access_token': token,
  'refresh_token': refresh,
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': probeUser(userId),
};

http.Response probeResponse(Map<String, dynamic> body, {int status = 200}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

class ProbePause {
  final started = Completer<void>();
  final response = Completer<http.Response>();
}

class ProbeProvider {
  final users = <String, Map<String, dynamic>>{};
  final _userPauses = <String, ProbePause>{};
  final requests = <String>[];
  ProbePause? refreshPause;
  Map<String, dynamic>? passwordReply;

  late final http.Client client = MockClient((request) async {
    final path = request.url.path;
    requests.add('${request.method} $path');
    if (path.endsWith('/user')) {
      final token = request.headers['Authorization']?.replaceFirst(
        'Bearer ',
        '',
      );
      final pause = _userPauses.remove(token);
      if (pause != null) {
        pause.started.complete();
        return pause.response.future;
      }
      final user = users[token];
      return user == null
          ? probeResponse({'msg': 'Invalid synthetic token'}, status: 401)
          : probeResponse(user);
    }
    if (path.endsWith('/logout')) return probeResponse({});
    if (path.endsWith('/token')) {
      if (request.url.queryParameters['grant_type'] == 'refresh_token') {
        final pause = refreshPause;
        if (pause == null) throw StateError('Unexpected refresh exchange');
        refreshPause = null;
        pause.started.complete();
        return pause.response.future;
      }
      final reply = passwordReply;
      if (reply != null) return probeResponse(reply);
    }
    throw StateError('Unexpected Auth probe request');
  });

  ProbePause pauseUser(String token) {
    final pause = ProbePause();
    _userPauses[token] = pause;
    return pause;
  }

  GoTrueClient createAuth() => GoTrueClient(
    url: 'https://auth-probe.invalid/auth/v1',
    autoRefreshToken: false,
    httpClient: client,
  );
}

class ProbeHandoff {
  const ProbeHandoff({
    required this.accessToken,
    this.refreshToken = 'synthetic-rotated-refresh',
    this.userId = probeUserA,
    this.sessionId = probeSessionA,
    this.requestId = 'owned-setup',
    this.purpose = 'enroll',
    this.securityRevision = 1,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final String sessionId;
  final String requestId;
  final String purpose;
  final int securityRevision;
}

class ProbeTicket {
  const ProbeTicket({
    required this.generation,
    required this.accessToken,
    required this.requestId,
    required this.purpose,
  });

  final int generation;
  final String accessToken;
  final String requestId;
  final String purpose;
}

class PreparedProbeHandoff {
  const PreparedProbeHandoff._(this.ticket, this.session);
  final ProbeTicket ticket;
  final Session session;
}

class ProbeRejected implements Exception {
  const ProbeRejected();
}

/// A deliberately small test candidate for the inspected pinned SDK. It first
/// validates using the real SDK's getClaims/getUser contracts, then constructs
/// its own Session and calls only recoverSession's fresh synchronous branch.
/// This must not be promoted into production on VM test evidence alone.
class GuardedHandoffProbe {
  GuardedHandoffProbe(this.auth);

  final GoTrueClient auth;
  int _generation = 0;
  ProbeTicket? _pending;
  int acceptedChanges = 0;

  ProbeTicket begin({
    String requestId = 'owned-setup',
    String purpose = 'enroll',
  }) {
    final current = auth.currentSession;
    if (!_matchesOrigin(current)) {
      throw const ProbeRejected();
    }
    final ticket = ProbeTicket(
      generation: _generation,
      accessToken: current!.accessToken,
      requestId: requestId,
      purpose: purpose,
    );
    _pending = ticket;
    return ticket;
  }

  void invalidate() {
    _generation++;
    _pending = null;
  }

  Future<void> signOut() {
    invalidate();
    return auth.signOut();
  }

  bool _matchesOrigin(Session? current) {
    if (current == null || current.user.id != probeUserA) return false;
    // A consistency check against the fixture's server-approved origin binding,
    // not authentication by client decoding. The rotated token is validated via
    // getClaims/getUser below; production needs its own server session boundary.
    final claims = decodeJwt(current.accessToken).payload;
    return claims.sub == probeUserA &&
        claims.claims['session_id'] == probeSessionA;
  }

  void _checkCurrent(ProbeTicket ticket) {
    if (!identical(_pending, ticket) ||
        ticket.generation != _generation ||
        !_matchesOrigin(auth.currentSession) ||
        auth.currentSession?.accessToken != ticket.accessToken) {
      throw const ProbeRejected();
    }
  }

  void _checkFresh(Session session) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expiry = session.expiresAt;
    if (expiry == null || expiry <= now + 60 || session.isExpired) {
      throw const ProbeRejected();
    }
  }

  Future<PreparedProbeHandoff> prepare(
    ProbeTicket ticket,
    ProbeHandoff handoff,
  ) async {
    _checkCurrent(ticket);
    if (handoff.refreshToken.isEmpty ||
        handoff.userId != probeUserA ||
        handoff.sessionId != probeSessionA ||
        handoff.requestId != ticket.requestId ||
        handoff.purpose != ticket.purpose ||
        handoff.securityRevision != 1) {
      throw const ProbeRejected();
    }
    // HS256 in the fixture makes getClaims validate at the fake /user endpoint.
    // Actual provider signature and claims behavior needs the isolated Auth run.
    final validated = await auth.getClaims(handoff.accessToken);
    if (validated.claims.sub != handoff.userId ||
        validated.claims.claims['session_id'] != handoff.sessionId) {
      throw const ProbeRejected();
    }
    final user = (await auth.getUser(handoff.accessToken)).user;
    if (user == null || user.id != handoff.userId) {
      throw const ProbeRejected();
    }
    final session = Session(
      accessToken: handoff.accessToken,
      refreshToken: handoff.refreshToken,
      tokenType: 'bearer',
      user: user,
    );
    _checkFresh(session);
    _checkCurrent(ticket);
    return PreparedProbeHandoff._(ticket, session);
  }

  Future<AuthResponse> commit(PreparedProbeHandoff prepared) {
    _checkFresh(prepared.session);
    _checkCurrent(prepared.ticket);
    // There is deliberately no await between the final check and SDK import.
    // The tests assert that the pinned fresh branch installs synchronously and
    // makes no HTTP request. Expired/malformed imports never reach this call.
    final result = auth.recoverSession(jsonEncode(prepared.session.toJson()));
    if (auth.currentSession?.accessToken != prepared.session.accessToken) {
      throw StateError('Pinned SDK no longer installs synchronously');
    }
    _pending = null;
    _generation++;
    acceptedChanges++;
    return result;
  }

  Future<AuthResponse> adopt(
    ProbeTicket ticket,
    ProbeHandoff handoff, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final prepared = await prepare(ticket, handoff).timeout(
      timeout,
      onTimeout: () {
        // Future.timeout cannot cancel provider work. Invalidating this lease
        // prevents its eventual reply from being imported after the deadline.
        if (identical(_pending, ticket)) _pending = null;
        throw const ProbeRejected();
      },
    );
    return commit(prepared);
  }
}
