// Isolated experiment only. No production app imports, real tokens or network.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:gotrue/gotrue.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

const customerA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const customerB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const sessionA = '11111111-1111-4111-8111-111111111111';
const sessionB = '22222222-2222-4222-8222-222222222222';

String alias(String? user) => switch (user) {
  customerA => 'customer-a',
  customerB => 'customer-b',
  null => 'signed-out',
  _ => 'unexpected-user',
};

Map<String, dynamic> fakeUser(String id) => {
  'id': id,
  'aud': 'authenticated',
  'role': 'authenticated',
  'app_metadata': <String, dynamic>{},
  'user_metadata': <String, dynamic>{},
  'created_at': '2026-01-01T00:00:00.000Z',
};

String fakeToken(String user, String session, int serial) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part({'sub': user, 'session_id': session, 'iat': now, 'exp': now + 3600, 'serial': serial})}.${part('synthetic-signature')}';
}

class HeldResponse {
  final arrived = Completer<void>();
  final release = Completer<void>();
}

class FakeTransport extends http.BaseClient {
  final users = <String, String>{};
  final held = <String, HeldResponse>{};
  int requests = 0;

  String issue(String user, String session, int serial) {
    final token = fakeToken(user, session, serial);
    users[token] = user;
    return token;
  }

  HeldResponse hold(String token) => held[token] = HeldResponse();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    // Every HTTP request is answered here. No BrowserClient exists in this test.
    if (request.url.path.endsWith('/logout')) {
      return http.StreamedResponse(Stream.value(<int>[]), 204);
    }
    if (request.url.path.endsWith('/user')) {
      final token =
          request.headers['Authorization']?.replaceFirst('Bearer ', '') ??
          request.headers['authorization']?.replaceFirst('Bearer ', '');
      final wait = held[token];
      if (wait != null) {
        if (!wait.arrived.isCompleted) wait.arrived.complete();
        await wait.release.future;
      }
      final user = users[token];
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode(
              user == null
                  ? {'message': 'Synthetic unauthorized'}
                  : fakeUser(user),
            ),
          ),
        ),
        user == null ? 401 : 200,
        headers: {'content-type': 'application/json'},
      );
    }
    throw StateError('Unexpected synthetic HTTP route');
  }
}

class Probe {
  Probe(this.run, this.role) {
    control = web.BroadcastChannel('nene-auth-probe-control-$run');
    control.onmessage = ((web.MessageEvent event) {
      final raw = event.data.dartify();
      if (raw is! String) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['source'] == role) return;
      if (data['kind'] == 'reply') {
        replies.remove(data['id'])?.complete(data);
      } else if (role == 'observer') {
        unawaited(onCommand(data));
      } else if (data['kind'] == 'ready') {
        if (!ready.isCompleted) ready.complete();
      }
    }).toJS;
  }

  final String run;
  final String role;
  late final web.BroadcastChannel control;
  final ready = Completer<void>();
  final replies = <int, Completer<Map<String, dynamic>>>{};
  final results = <Map<String, dynamic>>[];
  int serial = 0;
  int requestId = 0;
  GoTrueClient? observer;
  Timer? readiness;

  GoTrueClient client(FakeTransport transport) => GoTrueClient(
    url: 'https://nene-auth-probe-$run.invalid/auth/v1',
    autoRefreshToken: false,
    httpClient: transport,
  );

  void status(String value) =>
      web.document.querySelector('#status')!.textContent = value;

  void render(String state) {
    web.document.body!.setAttribute('data-probe-state', state);
    web.document
        .querySelector('#results')!
        .textContent = const JsonEncoder.withIndent('  ').convert({
      'state': state,
      'role': role,
      'sdk': 'gotrue 2.27.3 (installed package)',
      'provider':
          'fake HTTP; synthetic sessions; no provider authentication claim',
      'browser_transport': 'real native BroadcastChannel',
      'results': results,
    });
  }

  void send(Map<String, dynamic> message) =>
      control.postMessage(jsonEncode({...message, 'source': role}).toJS);

  Future<Map<String, dynamic>> command(String kind) {
    final id = ++requestId;
    final answer = Completer<Map<String, dynamic>>();
    replies[id] = answer;
    send({'kind': kind, 'id': id});
    return answer.future.timeout(const Duration(seconds: 5));
  }

  Future<void> onCommand(Map<String, dynamic> message) async {
    switch (message['kind']) {
      case 'reset':
        observer?.dispose();
        observer = client(FakeTransport());
        readiness?.cancel();
        status('Observer connected; receiving synthetic SDK events.');
      case 'snapshot':
        break;
      case 'finish':
        observer?.dispose();
        observer = null;
        readiness?.cancel();
        status('Observer completed; Auth client disposed.');
        render('complete');
      default:
        return;
    }
    send({
      'kind': 'reply',
      'id': message['id'],
      'user': alias(observer?.currentUser?.id),
    });
  }

  Future<void> expectPeer(String expected) async {
    // Wait for native cross-tab delivery, with an explicit bounded deadline.
    for (var attempt = 0; attempt < 30; attempt++) {
      if ((await command('snapshot'))['user'] == expected) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError(
      'Observer state did not reach expected synthetic identity',
    );
  }

  void expect(bool condition, String reason) {
    if (!condition) throw StateError(reason);
  }

  Future<void> scenario(
    String name,
    Future<void> Function(GoTrueClient, FakeTransport) action,
  ) async {
    await command('reset');
    final transport = FakeTransport();
    final auth = client(transport);
    try {
      await action(auth, transport).timeout(const Duration(seconds: 10));
      results.add({'name': name, 'result': 'observed-as-expected'});
      render('running');
    } finally {
      auth.dispose();
      transport.close();
    }
  }

  Future<void> lead() async {
    status('Waiting for the observer tab with the same run ID.');
    render('waiting');
    try {
      await ready.future.timeout(const Duration(seconds: 90));
      status('Running isolated SDK/browser cases…');

      await scenario(
        'memory-only candidate and second tab both receive session',
        (auth, http) async {
          final candidate = client(FakeTransport());
          try {
            final token = http.issue(customerA, sessionA, ++serial);
            await auth.setSession('synthetic-refresh', accessToken: token);
            await expectPeer('customer-a');
            for (var i = 0; candidate.currentUser == null && i < 30; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            expect(
              candidate.currentUser?.id == customerA,
              'Candidate was unexpectedly isolated',
            );
          } finally {
            candidate.dispose();
          }
        },
      );

      await scenario(
        'unguarded delayed setSession resurrects logout in both tabs',
        (auth, http) async {
          await auth.setSession(
            'synthetic-initial',
            accessToken: http.issue(customerA, sessionA, ++serial),
          );
          await expectPeer('customer-a');
          final token = http.issue(customerA, sessionA, ++serial);
          final held = http.hold(token);
          final pending = auth.setSession(
            'synthetic-rotated',
            accessToken: token,
          );
          await held.arrived.future;
          await auth.signOut(scope: SignOutScope.local);
          await expectPeer('signed-out');
          expect(auth.currentSession == null, 'Logout did not clear first');
          held.release.complete();
          await pending;
          expect(
            auth.currentUser?.id == customerA,
            'Expected stale setSession hazard was absent',
          );
          await expectPeer('customer-a');
        },
      );

      await scenario(
        'unguarded delayed setSession overwrites account switch in both tabs',
        (auth, http) async {
          await auth.setSession(
            'synthetic-initial',
            accessToken: http.issue(customerA, sessionA, ++serial),
          );
          await expectPeer('customer-a');
          final token = http.issue(customerA, sessionA, ++serial);
          final held = http.hold(token);
          final pending = auth.setSession(
            'synthetic-rotated',
            accessToken: token,
          );
          await held.arrived.future;
          await auth.setSession(
            'synthetic-other',
            accessToken: http.issue(customerB, sessionB, ++serial),
          );
          await expectPeer('customer-b');
          held.release.complete();
          await pending;
          expect(
            auth.currentUser?.id == customerA,
            'Expected account-switch hazard was absent',
          );
          await expectPeer('customer-a');
        },
      );

      await scenario(
        'prevalidated generation guard rejects late local reply after logout',
        (auth, http) async {
          await auth.setSession(
            'synthetic-initial',
            accessToken: http.issue(customerA, sessionA, ++serial),
          );
          await expectPeer('customer-a');
          var generation = 0;
          final captured = generation;
          final token = http.issue(customerA, sessionA, ++serial);
          final held = http.hold(token);
          final pending = () async {
            // getUser is the fake authority here. Real backend verification is a separate gate.
            final response = await auth.getUser(token);
            if (generation != captured || auth.currentUser?.id != customerA)
              return false;
            expect(
              response.user?.id == customerA,
              'Unexpected validated subject',
            );
            await auth.recoverSession(
              jsonEncode(
                Session(
                  accessToken: token,
                  refreshToken: 'synthetic-new',
                  tokenType: 'bearer',
                  user: response.user!,
                ).toJson(),
              ),
            );
            return true;
          }();
          await held.arrived.future;
          generation++;
          await auth.signOut(scope: SignOutScope.local);
          await expectPeer('signed-out');
          held.release.complete();
          expect(!await pending, 'Stale guarded import was accepted');
          expect(
            auth.currentSession == null,
            'Local guard resurrected a session',
          );
          await expectPeer('signed-out');
        },
      );

      await scenario(
        'late peer SDK broadcast bypasses a local-only generation guard',
        (auth, http) async {
          await auth.setSession(
            'synthetic-initial',
            accessToken: http.issue(customerA, sessionA, ++serial),
          );
          await expectPeer('customer-a');
          final peerHttp = FakeTransport();
          final peer = client(peerHttp);
          try {
            final token = peerHttp.issue(customerA, sessionA, ++serial);
            final held = peerHttp.hold(token);
            final pending = peer.setSession(
              'synthetic-peer',
              accessToken: token,
            );
            await held.arrived.future;
            await auth.signOut(scope: SignOutScope.local);
            await expectPeer('signed-out');
            held.release.complete();
            await pending;
            await expectPeer('customer-a');
            for (var i = 0; auth.currentSession == null && i < 30; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            expect(
              auth.currentUser?.id == customerA,
              'Expected late peer broadcast hazard was absent',
            );
          } finally {
            peer.dispose();
            peerHttp.close();
          }
        },
      );

      await command('finish');
      status(
        'Complete: expected hazards reproduced; local guard alone does not clear the browser integration gate.',
      );
      render('complete');
    } catch (error) {
      // Avoid printing provider objects, JWTs or raw exception payloads.
      results.add({
        'name': 'probe-failure',
        'result': 'failed',
        'error_type': error.runtimeType.toString(),
      });
      status('Probe failed or timed out; see sanitized results.');
      render('failed');
    } finally {
      control.close();
    }
  }

  void observe() {
    observer = client(FakeTransport());
    status('Observer ready; leave this tab open while the leader runs.');
    render('ready');
    send({'kind': 'ready'});
    readiness = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => send({'kind': 'ready'}),
    );
  }
}

void main() {
  final uri = Uri.parse(web.window.location.href);
  final run = uri.queryParameters['run'] ?? '';
  final role = uri.queryParameters['role'] ?? '';
  if (!RegExp(r'^[a-z0-9-]{8,64}$').hasMatch(run) ||
      !{'leader', 'observer'}.contains(role)) {
    web.document.querySelector('#status')!.textContent = 'Supply ?run=<unique-lowercase-id>&role=leader or role=observer in two tabs.';
    return;
  }
  final probe = Probe(run, role);
  if (role == 'leader') {
    unawaited(probe.lead());
  } else {
    probe.observe();
  }
}
