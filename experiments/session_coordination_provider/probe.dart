// Isolated real-provider exercise of the shared coordinator candidate. The
// parent supplies synthetic credentials once through stdin; nothing is persisted.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../session_coordinator/session_owner.dart';
import '../session_coordinator/supabase_auth_port.dart';

const _maximumBytes = 128 * 1024;
const _caseNames = [
  'verification_then_refresh',
  'refresh_then_verification',
  'logout_during_verification',
  'unknown_reply_requires_signin',
];

class _Failure implements Exception {
  const _Failure();
}

void _require(bool value) {
  if (!value) throw const _Failure();
}

Future<Uint8List> _boundedBytes(Stream<List<int>> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    _require(bytes.length + chunk.length <= _maximumBytes);
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

class _HeldResponse {
  final reached = Completer<void>();
  final release = Completer<void>();
}

/// Holds a real server reply after the server has already rotated/consumed its
/// credential. This tests application scheduling, not a fake token service.
class _TrackedClient extends http.BaseClient {
  _TrackedClient(this.origin);
  final Uri origin;
  final _inner = http.Client();
  final _holds = <String, _HeldResponse>{};
  final calls = <String>[];
  final sentRefreshTokens = <String>[];
  String? verifiedRefreshToken;
  String? refreshedAccessToken;
  String? refreshedRefreshToken;
  String? verificationAccessToken;

  _HeldResponse hold(String action) {
    _require(!_holds.containsKey(action));
    final result = _HeldResponse();
    _holds[action] = result;
    return result;
  }

  int count(String action) => calls.where((value) => value == action).length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _require(request.url.origin == origin.origin);
    final action = switch ((request.method, request.url.path)) {
      ('GET', '/user') when request.url.query.isEmpty => 'validate',
      ('POST', '/token') when request.url.query == 'grant_type=password' =>
        'signin',
      ('POST', '/token') when request.url.query == 'grant_type=refresh_token' =>
        'refresh',
      ('POST', '/factors/recovery-codes/verify')
          when request.url.query.isEmpty =>
        'verify',
      ('POST', '/logout')
          when request.url.query.isEmpty ||
              request.url.query == 'scope=local' =>
        'logout',
      _ => throw const _Failure(),
    };
    calls.add(action);
    if (action == 'refresh') {
      _require(request is http.Request);
      final body =
          jsonDecode((request as http.Request).body) as Map<String, dynamic>;
      sentRefreshTokens.add(body['refresh_token'] as String);
    } else if (action == 'verify') {
      verificationAccessToken = request.headers['Authorization']?.replaceFirst(
        'Bearer ',
        '',
      );
    }
    request.followRedirects = false;
    request.maxRedirects = 0;
    final response = await _inner
        .send(request)
        .timeout(const Duration(seconds: 10));
    final body = await _boundedBytes(response.stream)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode == 200 &&
        (action == 'refresh' || action == 'verify')) {
      final session = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      if (action == 'verify') {
        verifiedRefreshToken = session['refresh_token'] as String;
      } else {
        refreshedAccessToken = session['access_token'] as String;
        refreshedRefreshToken = session['refresh_token'] as String;
      }
    }
    final held = _holds.remove(action);
    if (held != null) {
      held.reached.complete();
      await held.release.future.timeout(const Duration(seconds: 12));
    }
    return http.StreamedResponse(
      Stream.value(body),
      response.statusCode,
      headers: response.headers,
      contentLength: body.length,
      request: response.request,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
    );
  }

  @override
  void close() => _inner.close();
}

Map<String, dynamic> _claims(OwnedSession session) {
  // Diagnostics only, after the shared port validated this exact token at /user.
  // The coordinator's server boundary, not this decoder, establishes identity.
  final parts = session.pair.accessToken.split('.');
  _require(parts.length == 3);
  return jsonDecode(
    utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
  ) as Map<String, dynamic>;
}

Future<AuthPair> _verify(
  _TrackedClient client,
  OwnedSession session,
  String code,
) async {
  final request = http.Request(
    'POST',
    client.origin.resolve('/factors/recovery-codes/verify'),
  );
  request.headers.addAll({
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ${session.pair.accessToken}',
  });
  request.body = jsonEncode({'code': code});
  final response = await client.send(request);
  final bytes = await _boundedBytes(response.stream);
  _require(response.statusCode == 200);
  final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  return AuthPair(
    accessToken: body['access_token'] as String,
    refreshToken: body['refresh_token'] as String,
  );
}

Future<bool> _outcome(Future<void> work) =>
    work.then((_) => true, onError: (Object _, StackTrace __) => false);

Future<void> _settleQueue() => Future<void>.delayed(Duration.zero);

Future<void> _exercise(Uri origin, Map<String, dynamic> input) async {
  final name = input['name'] as String;
  final email = input['email'] as String;
  final password = input['password'] as String;
  final expectedUser = input['expectedUserId'] as String;
  final code = input['recoveryCode'] as String;
  final client = _TrackedClient(origin);
  final port = SupabaseAuthPort(authOrigin: origin, client: client);
  final owner = SessionOwner(port);
  final binding = HandoffBinding(
    requestId: name,
    purpose: 'recovery',
    securityRevision: 1,
  );
  try {
    await owner.signIn(email, password);
    final initial = owner.session!;
    _require(initial.userId == expectedUser);
    _require(_claims(initial)['aal'] == 'aal1');
    Future<HandoffReply> exchange(OwnedSession current) async {
      if (name == 'refresh_then_verification') {
        _require(current.pair.refreshToken == client.refreshedRefreshToken);
      }
      return HandoffReply(
        pair: await _verify(client, current, code),
        binding: binding,
      );
    }

    switch (name) {
      case 'verification_then_refresh':
        final held = client.hold('verify');
        final verification = owner.exchange(binding, exchange);
        await held.reached.future;
        final refresh = owner.refresh();
        await _settleQueue();
        _require(client.count('refresh') == 0);
        held.release.complete();
        await verification;
        await refresh;
        _require(client.count('verify') == 1 && client.count('refresh') == 1);
        _require(
          client.sentRefreshTokens.single == client.verifiedRefreshToken,
        );
        _require(owner.session!.userId == expectedUser);
        _require(owner.session!.sessionId == initial.sessionId);
        _require(_claims(owner.session!)['aal'] == 'aal2');
        // Beyond the fixture's 10-second reuse interval: do not rely on grace.
        await Future<void>.delayed(const Duration(seconds: 11));
        await owner.refresh();
        _require(client.count('refresh') == 2);
        _require(owner.session!.sessionId == initial.sessionId);
        _require(_claims(owner.session!)['aal'] == 'aal2');
      case 'refresh_then_verification':
        final held = client.hold('refresh');
        final refresh = owner.refresh();
        await held.reached.future;
        final verification = owner.exchange(binding, exchange);
        await _settleQueue();
        _require(client.count('verify') == 0);
        held.release.complete();
        await refresh;
        await verification;
        _require(
          client.calls.indexOf('refresh') < client.calls.indexOf('verify'),
        );
        _require(client.verificationAccessToken == client.refreshedAccessToken);
        _require(owner.session!.sessionId == initial.sessionId);
        _require(_claims(owner.session!)['aal'] == 'aal2');
        await Future<void>.delayed(const Duration(seconds: 11));
        await owner.refresh();
        _require(client.count('refresh') == 2);
        _require(owner.session!.sessionId == initial.sessionId);
        _require(_claims(owner.session!)['aal'] == 'aal2');
      case 'logout_during_verification':
        final held = client.hold('verify');
        final verification = _outcome(owner.exchange(binding, exchange));
        await held.reached.future;
        final refresh = _outcome(owner.refresh());
        final logout = owner.signOut();
        _require(owner.session == null);
        held.release.complete();
        _require(!await verification);
        _require(!await refresh);
        await logout;
        _require(owner.session == null && client.count('refresh') == 0);
      case 'unknown_reply_requires_signin':
        final held = client.hold('verify');
        final verification = _outcome(
          owner.exchange(binding, (current) async {
            await _verify(client, current, code);
            // The provider consumed the code, but the caller loses the pair.
            throw TimeoutException('Synthetic discarded provider reply');
          }),
        );
        await held.reached.future;
        final refresh = _outcome(owner.refresh());
        held.release.complete();
        _require(!await verification);
        _require(!await refresh);
        _require(owner.session == null && client.count('refresh') == 0);
        _require(client.count('verify') == 1);
        await owner.signIn(email, password);
        _require(owner.session!.sessionId != initial.sessionId);
        _require(_claims(owner.session!)['aal'] == 'aal1');
        await owner.refresh();
        _require(client.count('verify') == 1 && client.count('refresh') == 1);
        _require(_claims(owner.session!)['aal'] == 'aal1');
      default:
        throw const _Failure();
    }
  } finally {
    owner.dispose();
    client.close();
  }
}

Future<void> main() async {
  var stage = 'read_input';
  try {
    final bytes = await _boundedBytes(stdin)
        .timeout(const Duration(seconds: 5));
    final input = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    _require(input.keys.toSet().containsAll({'authOrigin', 'cases'}));
    _require(input.length == 2);
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
    final cases = (input['cases'] as List).cast<Map<String, dynamic>>();
    _require(cases.length == _caseNames.length);
    final results = <Map<String, Object>>[];
    for (var i = 0; i < cases.length; i++) {
      final entry = cases[i];
      _require(entry['name'] == _caseNames[i]);
      _require(
        entry.values.every((value) => value is String && value.isNotEmpty),
      );
      _require(entry.length == 5);
      stage = _caseNames[i];
      await _exercise(origin, entry).timeout(const Duration(seconds: 30));
      results.add({'name': _caseNames[i], 'passed': true});
    }
    stdout.writeln(
      jsonEncode({
        'result': 'passed',
        'probe': 'real_provider_session_coordination',
        'cases': results,
        'appIntegration': false,
        'moneyMoved': false,
      }),
    );
  } catch (_) {
    // Provider errors and input contain credentials; never dump them or stacks.
    stderr.writeln(
      jsonEncode({
        'result': 'failed',
        'probe': 'real_provider_session_coordination',
        'stage': stage,
      }),
    );
    exitCode = 1;
  }
}
