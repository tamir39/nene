// Test harness only: fake AuthPort, real session owner and legacy SDK broadcasts.
// The coordinator has no SDK client, browser channel or persistent storage.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:gotrue/gotrue.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../session_coordinator/session_owner.dart';

const customerA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const customerB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const legacySession = '11111111-1111-4111-8111-111111111111';

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

class Hold {
  final started = Completer<void>();
  final release = Completer<void>();
}

class FakePort implements AuthPort {
  FakePort(this.role);
  final String role;
  final sessions = <String, OwnedSession>{};
  final refreshInputs = <String>[];
  int serial = 0;
  int logins = 0;
  int activeRefreshes = 0;
  int maximumRefreshes = 0;
  Hold? heldRefresh;

  AuthPair issue(String user, String session) {
    final token = fakeToken(user, session, ++serial);
    final pair = AuthPair(
      accessToken: token,
      refreshToken: 'synthetic-$role-$serial',
    );
    sessions[token] = OwnedSession(
      pair: pair,
      userId: user,
      sessionId: session,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    return pair;
  }

  AuthPair rotate(OwnedSession session) =>
      issue(session.userId, session.sessionId);

  @override
  Future<AuthPair> signIn(String email, String password) async {
    final suffix = (++logins).toString().padLeft(12, '0');
    final session =
        '${role == 'leader' ? '22222222' : '33333333'}-2222-4222-8222-$suffix';
    return issue(email == 'b' ? customerB : customerA, session);
  }

  @override
  Future<AuthPair> refresh(OwnedSession session) async {
    refreshInputs.add(session.pair.accessToken);
    activeRefreshes++;
    if (activeRefreshes > maximumRefreshes) maximumRefreshes = activeRefreshes;
    try {
      final held = heldRefresh;
      heldRefresh = null;
      if (held != null) {
        held.started.complete();
        await held.release.future;
      }
      return rotate(session);
    } finally {
      activeRefreshes--;
    }
  }

  @override
  Future<OwnedSession> validate(AuthPair pair) async {
    final session = sessions[pair.accessToken];
    if (session == null || session.pair.refreshToken != pair.refreshToken) {
      throw StateError('Unknown synthetic pair');
    }
    return session;
  }

  @override
  Future<void> signOut(OwnedSession session) async {}
}

class LegacyTransport extends http.BaseClient {
  final users = <String, String>{};
  final holds = <String, Hold>{};
  int serial = 0;

  String issue(String user) {
    final token = fakeToken(user, legacySession, ++serial);
    users[token] = user;
    return token;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // There is no BrowserClient in this transport: every request stays in memory.
    if (request.url.path.endsWith('/logout')) {
      return http.StreamedResponse(Stream.value(<int>[]), 204);
    }
    if (!request.url.path.endsWith('/user')) {
      throw StateError('Unexpected synthetic legacy route');
    }
    final token =
        request.headers['Authorization']?.replaceFirst('Bearer ', '') ??
        request.headers['authorization']?.replaceFirst('Bearer ', '');
    final hold = holds[token];
    if (hold != null) {
      hold.started.complete();
      await hold.release.future;
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
}

class Probe {
  Probe(this.run, this.role) {
    channel = web.BroadcastChannel('nene-owner-probe-control-$run');
    channel.onmessage = ((web.MessageEvent event) {
      final raw = event.data.dartify();
      if (raw is! String) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['source'] == role) return;
      if (data['kind'] == 'reply') {
        replies.remove(data['id'])?.complete(data);
      } else if (role == 'observer') {
        unawaited(onCommand(data));
      } else if (data['kind'] == 'ready' && !ready.isCompleted) {
        ready.complete();
      }
    }).toJS;
  }

  final String run;
  final String role;
  late final web.BroadcastChannel channel;
  final ready = Completer<void>();
  final replies = <int, Completer<Map<String, dynamic>>>{};
  final results = <Map<String, dynamic>>[];
  SessionOwner? owner;
  FakePort? port;
  GoTrueClient? control;
  LegacyTransport? controlTransport;
  Timer? readiness;
  int requestId = 0;
  int bindingId = 0;

  GoTrueClient legacy(LegacyTransport transport) => GoTrueClient(
    url: 'https://nene-owner-legacy-$run.invalid/auth/v1',
    autoRefreshToken: false,
    httpClient: transport,
  );

  void reset({Duration timeout = const Duration(seconds: 3)}) {
    owner?.dispose();
    control?.dispose();
    controlTransport?.close();
    port = FakePort(role);
    owner = SessionOwner(port!, timeout: timeout);
    controlTransport = LegacyTransport();
    control = legacy(controlTransport!);
  }

  Map<String, dynamic> snapshot() => {
    'owner': alias(owner?.session?.userId),
    'owner_session': owner?.session?.sessionId,
    'legacy_control': alias(control?.currentUser?.id),
  };

  void render(String state) {
    web.document.body!.setAttribute('data-probe-state', state);
    web.document.body!.setAttribute(
      'data-owner-user',
      alias(owner?.session?.userId),
    );
    web.document
        .querySelector('#results')!
        .textContent = const JsonEncoder.withIndent('  ').convert({
      'state': state,
      'role': role,
      'coordinator': 'isolated SessionOwner with fake AuthPort',
      'legacy_sdk': 'real gotrue 2.27.3 browser control',
      'browser_transport': 'real native BroadcastChannel',
      'results': results,
    });
  }

  void status(String text) =>
      web.document.querySelector('#status')!.textContent = text;
  void expect(bool condition, String reason) {
    if (!condition) throw StateError(reason);
  }

  void send(Map<String, dynamic> message) =>
      channel.postMessage(jsonEncode({...message, 'source': role}).toJS);

  Future<Map<String, dynamic>> command(String kind) {
    final id = ++requestId;
    final result = Completer<Map<String, dynamic>>();
    replies[id] = result;
    send({'kind': kind, 'id': id});
    return result.future.timeout(const Duration(seconds: 5));
  }

  Future<void> onCommand(Map<String, dynamic> message) async {
    switch (message['kind']) {
      case 'reset':
        reset();
        readiness?.cancel();
      case 'signin-a':
        await owner!.signIn('a', 'synthetic-only');
      case 'signin-b':
        await owner!.signIn('b', 'synthetic-only');
      case 'signout':
        await owner!.signOut();
      case 'snapshot':
        break;
      case 'finish':
        readiness?.cancel();
        status('Observer remains signed in for the separate reload check.');
      default:
        return;
    }
    render(message['kind'] == 'finish' ? 'complete' : 'ready');
    send({'kind': 'reply', 'id': message['id'], ...snapshot()});
  }

  Future<void> expectLegacy(String expected) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      final peer = await command('snapshot');
      if (alias(control?.currentUser?.id) == expected &&
          peer['legacy_control'] == expected)
        return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw StateError('Legacy control did not receive the tested SDK event');
  }

  HandoffBinding binding() => HandoffBinding(
    requestId: 'synthetic-request-${++bindingId}',
    purpose: 'replace',
    securityRevision: 1,
  );

  Future<void> scenario(String name, Future<void> Function() action) async {
    await command('reset');
    reset();
    await action().timeout(const Duration(seconds: 10));
    results.add({'name': name, 'result': 'passed'});
    render('running');
  }

  Future<void> lead() async {
    status('Waiting for the observer tab.');
    render('waiting');
    try {
      await ready.future.timeout(const Duration(seconds: 90));

      await scenario('independent memory ownership across two tabs', () async {
        await owner!.signIn('a', 'synthetic-only');
        final before = owner!.session!;
        final peer = await command('signin-a');
        expect(
          peer['owner_session'] != before.sessionId,
          'Tabs shared a session',
        );
        await command('signin-b');
        expect(identical(owner!.session, before), 'Peer login replaced owner');
        expect(
          alias(control!.currentUser?.id) == 'signed-out',
          'Owner broadcast its session',
        );
      });

      await scenario(
        'late SDK broadcast reaches controls but cannot undo logout',
        () async {
          await owner!.signIn('a', 'synthetic-only');
          await command('signin-b');
          final http = LegacyTransport();
          final sender = legacy(http);
          try {
            final token = http.issue(customerA);
            final hold = http.holds[token] = Hold();
            final pending = sender.setSession(
              'synthetic-legacy-refresh',
              accessToken: token,
            );
            await hold.started.future;
            await owner!.signOut();
            hold.release.complete();
            await pending;
            await expectLegacy('customer-a');
            expect(
              owner!.session == null,
              'Legacy event restored signed-out owner',
            );
            expect(
              (await command('snapshot'))['owner'] == 'customer-b',
              'Legacy event replaced peer owner',
            );
          } finally {
            sender.dispose();
            http.close();
          }
        },
      );

      await scenario(
        'late SDK broadcast cannot overwrite a later customer',
        () async {
          await owner!.signIn('a', 'synthetic-only');
          await command('signin-a');
          final http = LegacyTransport();
          final sender = legacy(http);
          try {
            final token = http.issue(customerA);
            final hold = http.holds[token] = Hold();
            final pending = sender.setSession(
              'synthetic-legacy-refresh',
              accessToken: token,
            );
            await hold.started.future;
            await owner!.signIn('b', 'synthetic-only');
            final current = owner!.session;
            hold.release.complete();
            await pending;
            await expectLegacy('customer-a');
            expect(
              identical(owner!.session, current),
              'Legacy event overwrote new customer',
            );
            expect(
              (await command('snapshot'))['owner'] == 'customer-a',
              'Peer owner changed',
            );
          } finally {
            sender.dispose();
            http.close();
          }
        },
      );

      await scenario(
        'delayed owned exchange cannot undo immediate logout',
        () async {
          await owner!.signIn('a', 'synthetic-only');
          final held = Hold();
          final request = binding();
          final pending = owner!
              .exchange(request, (session) async {
                held.started.complete();
                await held.release.future;
                return HandoffReply(
                  pair: port!.rotate(session),
                  binding: request,
                );
              })
              .then((_) => true, onError: (Object _) => false);
          await held.started.future;
          final logout = owner!.signOut();
          expect(owner!.session == null, 'Logout did not clear synchronously');
          held.release.complete();
          expect(!await pending, 'Old exchange was adopted');
          await logout;
          expect(owner!.session == null, 'Old reply restored the owner');
        },
      );

      await scenario(
        'delayed owned exchange cannot overwrite account switch',
        () async {
          await owner!.signIn('a', 'synthetic-only');
          final held = Hold();
          final request = binding();
          final pending = owner!
              .exchange(request, (session) async {
                held.started.complete();
                await held.release.future;
                return HandoffReply(
                  pair: port!.rotate(session),
                  binding: request,
                );
              })
              .then((_) => true, onError: (Object _) => false);
          await held.started.future;
          final switched = owner!.signIn('b', 'synthetic-only');
          expect(owner!.session == null, 'Switch did not clear old customer');
          held.release.complete();
          expect(!await pending, 'Old exchange was adopted after switch');
          await switched;
          expect(
            owner!.session?.userId == customerB,
            'New customer not retained',
          );
        },
      );

      await scenario(
        'peer owner and legacy SDK logout cannot clear independent owner',
        () async {
          await owner!.signIn('a', 'synthetic-only');
          await command('signin-b');
          final before = owner!.session;
          await command('signout');
          expect(
            identical(owner!.session, before),
            'Peer logout cleared owner',
          );
          final token = controlTransport!.issue(customerB);
          await control!.setSession('synthetic-control', accessToken: token);
          await expectLegacy('customer-b');
          await control!.signOut(scope: SignOutScope.local);
          await expectLegacy('signed-out');
          expect(
            identical(owner!.session, before),
            'Legacy logout cleared owner',
          );
        },
      );

      await scenario(
        'queued refreshes serialize and use latest owned pair',
        () async {
          await owner!.signIn('a', 'synthetic-only');
          final held = port!.heldRefresh = Hold();
          final first = owner!.refresh();
          await held.started.future;
          final second = owner!.refresh();
          await Future<void>.delayed(Duration.zero);
          expect(port!.refreshInputs.length == 1, 'Refreshes overlapped');
          held.release.complete();
          await Future.wait([first, second]);
          expect(
            port!.refreshInputs.length == 2 && port!.maximumRefreshes == 1,
            'Refresh serialization failed',
          );
          expect(
            port!.refreshInputs[0] != port!.refreshInputs[1],
            'Queued refresh reused stale pair',
          );
        },
      );

      await scenario(
        'exchange holds rotation lease before queued refresh',
        () async {
          await owner!.signIn('a', 'synthetic-only');
          final held = Hold();
          final request = binding();
          String? exchangedToken;
          final exchange = owner!.exchange(request, (session) async {
            held.started.complete();
            await held.release.future;
            final pair = port!.rotate(session);
            exchangedToken = pair.accessToken;
            return HandoffReply(pair: pair, binding: request);
          });
          await held.started.future;
          final refresh = owner!.refresh();
          await Future<void>.delayed(Duration.zero);
          expect(port!.refreshInputs.isEmpty, 'Refresh overtook exchange');
          held.release.complete();
          await Future.wait([exchange, refresh]);
          expect(
            port!.refreshInputs.single == exchangedToken,
            'Refresh used pre-exchange pair',
          );
        },
      );

      await scenario(
        'timed-out exchange and later SDK event cannot restore owner',
        () async {
          reset(timeout: const Duration(milliseconds: 50));
          await owner!.signIn('a', 'synthetic-only');
          final held = Hold();
          final request = binding();
          final pending = owner!
              .exchange(request, (session) async {
                held.started.complete();
                await held.release.future;
                return HandoffReply(
                  pair: port!.rotate(session),
                  binding: request,
                );
              })
              .then((_) => true, onError: (Object _) => false);
          await held.started.future;
          expect(!await pending, 'Timed-out exchange unexpectedly succeeded');
          expect(owner!.session == null, 'Unknown rotation retained old pair');
          final token = controlTransport!.issue(customerA);
          await control!.setSession('synthetic-late', accessToken: token);
          await expectLegacy('customer-a');
          held.release.complete();
          await Future<void>.delayed(const Duration(milliseconds: 25));
          expect(owner!.session == null, 'Late work restored timed-out owner');
        },
      );

      // Leave an explicit independent observer login for the runner's real reload.
      await command('signin-b');
      final finished = await command('finish');
      expect(
        finished['owner'] == 'customer-b',
        'Observer was not ready for reload',
      );
      status(
        'Complete: owner isolation and serialized rotations passed. Reload is checked separately by the runner.',
      );
      render('complete');
    } catch (error) {
      results.add({
        'name': 'probe-failure',
        'result': 'failed',
        'error_type': error.runtimeType.toString(),
      });
      status('Probe failed; see sanitized results.');
      render('failed');
    } finally {
      owner?.dispose();
      control?.dispose();
      controlTransport?.close();
      channel.close();
    }
  }

  void observe() {
    reset();
    status('Observer ready. Independent owner starts signed out.');
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
    web.document.querySelector('#status')!.textContent = 'Supply the same unique run ID with role=leader and role=observer in two tabs.';
    return;
  }
  final probe = Probe(run, role);
  if (role == 'leader') {
    unawaited(probe.lead());
  } else {
    probe.observe();
  }
}
