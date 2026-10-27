import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'session_handoff_fixture.dart';

// These are real pinned SDK state transitions with synthetic HTTP responses.
// No live Auth, app integration, browser broadcast, or financial execution is
// exercised. Tests documenting unsafe raw SDK behavior deliberately assert it.
void main() {
  late ProbeProvider provider;
  late GoTrueClient auth;
  late String initial;
  late String rotated;
  late GuardedHandoffProbe guarded;

  setUp(() async {
    provider = ProbeProvider();
    auth = provider.createAuth();
    initial = probeToken();
    rotated = probeToken(label: 'rotated');
    provider.users[initial] = probeUser(probeUserA);
    provider.users[rotated] = probeUser(probeUserA);
    await auth.setInitialSession(jsonEncode(probeSession(initial)));
    guarded = GuardedHandoffProbe(auth);
  });

  tearDown(() {
    auth.dispose();
    provider.client.close();
  });

  group('documented setSession baseline', () {
    test(
      'fresh access pair validates user without a refresh exchange',
      () async {
        await auth.setSession(
          'synthetic-rotated-refresh',
          accessToken: rotated,
        );
        expect(auth.currentSession?.accessToken, rotated);
        expect(provider.requests, ['GET /auth/v1/user']);
      },
    );

    test(
      'late user reply installs after sign-out: reproduced hazard',
      () async {
        final pause = provider.pauseUser(rotated);
        final pending = auth.setSession(
          'synthetic-rotated-refresh',
          accessToken: rotated,
        );
        await pause.started.future;
        await auth.signOut();
        expect(auth.currentSession, isNull);
        pause.response.complete(probeResponse(probeUser(probeUserA)));
        await pending;
        expect(auth.currentUser?.id, probeUserA);
        expect(auth.currentSession?.accessToken, rotated);
      },
    );

    test(
      'late user reply replaces a different login: reproduced hazard',
      () async {
        final pause = provider.pauseUser(rotated);
        final pending = auth.setSession(
          'synthetic-rotated-refresh',
          accessToken: rotated,
        );
        await pause.started.future;
        final other = probeToken(userId: probeUserB, sessionId: probeSessionB);
        provider.passwordReply = probeSession(other, userId: probeUserB);
        await auth.signInWithPassword(
          email: 'other@example.invalid',
          password: 'synthetic-only',
        );
        expect(auth.currentUser?.id, probeUserB);
        pause.response.complete(probeResponse(probeUser(probeUserA)));
        await pending;
        expect(auth.currentUser?.id, probeUserA);
      },
    );

    test('unvalidated recoverSession does not consult the provider', () async {
      final untrusted = probeToken(
        userId: probeUserB,
        sessionId: probeSessionB,
      );
      await auth.recoverSession(
        jsonEncode(probeSession(untrusted, userId: probeUserB)),
      );
      expect(auth.currentUser?.id, probeUserB);
      expect(provider.requests, isEmpty);
    });
  });

  test(
    'Future timeout alone does not stop late session installation',
    () async {
      final pause = provider.pauseUser(rotated);
      final pending = auth.setSession(
        'synthetic-rotated-refresh',
        accessToken: rotated,
      );
      final timedOut = expectLater(
        pending.timeout(const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
      await pause.started.future;
      await timedOut;
      expect(auth.currentSession?.accessToken, initial);
      pause.response.complete(probeResponse(probeUser(probeUserA)));
      await pending;
      expect(auth.currentSession?.accessToken, rotated);
    },
  );

  group('isolated guarded import candidate', () {
    test('validates first and imports synchronously without refresh', () async {
      final prepared = await guarded.prepare(
        guarded.begin(),
        ProbeHandoff(accessToken: rotated),
      );
      expect(auth.currentSession?.accessToken, initial);
      final requestsBeforeCommit = List<String>.of(provider.requests);
      final pending = guarded.commit(prepared);
      expect(auth.currentSession?.accessToken, rotated);
      expect(provider.requests, requestsBeforeCommit);
      await pending;
      expect(guarded.acceptedChanges, 1);
      expect(provider.requests, ['GET /auth/v1/user', 'GET /auth/v1/user']);
    });

    test('late validation after logout cannot install a session', () async {
      final pause = provider.pauseUser(rotated);
      final pending = guarded.adopt(
        guarded.begin(),
        ProbeHandoff(accessToken: rotated),
      );
      final rejection = expectLater(pending, throwsA(isA<ProbeRejected>()));
      await pause.started.future;
      await guarded.signOut();
      pause.response.complete(probeResponse(probeUser(probeUserA)));
      await rejection;
      expect(auth.currentSession, isNull);
      expect(guarded.acceptedChanges, 0);
    });

    test('logout between prepare and commit wins', () async {
      final prepared = await guarded.prepare(
        guarded.begin(),
        ProbeHandoff(accessToken: rotated),
      );
      await guarded.signOut();
      expect(() => guarded.commit(prepared), throwsA(isA<ProbeRejected>()));
      expect(auth.currentSession, isNull);
    });

    test('timed-out validation cannot install its eventual reply', () async {
      final pause = provider.pauseUser(rotated);
      final pending = guarded.adopt(
        guarded.begin(),
        ProbeHandoff(accessToken: rotated),
        timeout: const Duration(milliseconds: 50),
      );
      final rejected = expectLater(pending, throwsA(isA<ProbeRejected>()));
      await pause.started.future;
      await rejected;
      pause.response.complete(probeResponse(probeUser(probeUserA)));
      await Future<void>.delayed(Duration.zero);
      expect(auth.currentSession?.accessToken, initial);
      expect(guarded.acceptedChanges, 0);
    });

    test('timed-out old validation does not cancel a newer lease', () async {
      final pause = provider.pauseUser(rotated);
      final pending = guarded.adopt(
        guarded.begin(),
        ProbeHandoff(accessToken: rotated),
        timeout: const Duration(milliseconds: 50),
      );
      final rejected = expectLater(pending, throwsA(isA<ProbeRejected>()));
      await pause.started.future;
      final newerTicket = guarded.begin(requestId: 'newer-setup');
      await rejected;
      final newer = probeToken(label: 'newer-after-timeout');
      provider.users[newer] = probeUser(probeUserA);
      await guarded.adopt(
        newerTicket,
        ProbeHandoff(accessToken: newer, requestId: 'newer-setup'),
      );
      pause.response.complete(probeResponse(probeUser(probeUserA)));
      await Future<void>.delayed(Duration.zero);
      expect(auth.currentSession?.accessToken, newer);
      expect(guarded.acceptedChanges, 1);
    });

    test('different customer login defeats pending validation', () async {
      final pause = provider.pauseUser(rotated);
      final pending = guarded.adopt(
        guarded.begin(),
        ProbeHandoff(accessToken: rotated),
      );
      final rejection = expectLater(pending, throwsA(isA<ProbeRejected>()));
      await pause.started.future;
      final other = probeToken(userId: probeUserB, sessionId: probeSessionB);
      provider.passwordReply = probeSession(other, userId: probeUserB);
      guarded.invalidate();
      await auth.signInWithPassword(
        email: 'other@example.invalid',
        password: 'synthetic-only',
      );
      pause.response.complete(probeResponse(probeUser(probeUserA)));
      await rejection;
      expect(auth.currentUser?.id, probeUserB);
    });

    test(
      'superseded request cannot replace a newer accepted handoff',
      () async {
        final pause = provider.pauseUser(rotated);
        final oldPending = guarded.adopt(
          guarded.begin(),
          ProbeHandoff(accessToken: rotated),
        );
        final rejection = expectLater(
          oldPending,
          throwsA(isA<ProbeRejected>()),
        );
        await pause.started.future;
        final newer = probeToken(label: 'newer-handoff');
        provider.users[newer] = probeUser(probeUserA);
        await guarded.adopt(
          guarded.begin(requestId: 'newer-setup'),
          ProbeHandoff(accessToken: newer, requestId: 'newer-setup'),
        );
        pause.response.complete(probeResponse(probeUser(probeUserA)));
        await rejection;
        expect(auth.currentSession?.accessToken, newer);
        expect(guarded.acceptedChanges, 1);
      },
    );

    test('same handoff cannot be committed twice', () async {
      final prepared = await guarded.prepare(
        guarded.begin(),
        ProbeHandoff(accessToken: rotated),
      );
      await guarded.commit(prepared);
      expect(() => guarded.commit(prepared), throwsA(isA<ProbeRejected>()));
      expect(guarded.acceptedChanges, 1);
    });

    test(
      'fresh same-customer login cannot start an old-session handoff',
      () async {
        final newLogin = probeToken(sessionId: probeSessionB);
        provider.passwordReply = probeSession(newLogin);
        await auth.signInWithPassword(
          email: 'same-customer@example.invalid',
          password: 'synthetic-only',
        );
        expect(() => guarded.begin(), throwsA(isA<ProbeRejected>()));
        expect(auth.currentSession?.accessToken, newLogin);
      },
    );

    test(
      'fresh same-customer login invalidates already prepared handoff',
      () async {
        final prepared = await guarded.prepare(
          guarded.begin(),
          ProbeHandoff(accessToken: rotated),
        );
        final newLogin = probeToken(sessionId: probeSessionB);
        provider.passwordReply = probeSession(newLogin);
        await auth.signInWithPassword(
          email: 'same-customer@example.invalid',
          password: 'synthetic-only',
        );
        expect(() => guarded.commit(prepared), throwsA(isA<ProbeRejected>()));
        expect(auth.currentSession?.accessToken, newLogin);
      },
    );

    for (final invalid in <String, ProbeHandoff Function(String)>{
      'wrong envelope customer': (token) =>
          ProbeHandoff(accessToken: token, userId: probeUserB),
      'wrong envelope session': (token) =>
          ProbeHandoff(accessToken: token, sessionId: probeSessionB),
      'wrong request': (token) =>
          ProbeHandoff(accessToken: token, requestId: 'another-request'),
      'wrong purpose': (token) =>
          ProbeHandoff(accessToken: token, purpose: 'payment'),
      'stale security revision': (token) =>
          ProbeHandoff(accessToken: token, securityRevision: 0),
      'empty refresh token': (token) =>
          ProbeHandoff(accessToken: token, refreshToken: ''),
    }.entries) {
      test('${invalid.key} fails before provider calls', () async {
        await expectLater(
          guarded.adopt(guarded.begin(), invalid.value(rotated)),
          throwsA(isA<ProbeRejected>()),
        );
        expect(auth.currentSession?.accessToken, initial);
        expect(provider.requests, isEmpty);
      });
    }

    for (final remaining in [-10, 10, 50]) {
      test(
        'expired or near-expiry pair ($remaining seconds) is rejected',
        () async {
          final token = probeToken(remainingSeconds: remaining);
          provider.users[token] = probeUser(probeUserA);
          await expectLater(
            guarded.adopt(guarded.begin(), ProbeHandoff(accessToken: token)),
            throwsA(anyOf(isA<ProbeRejected>(), isA<AuthException>())),
          );
          expect(auth.currentSession?.accessToken, initial);
          expect(
            provider.requests.where((path) => path.contains('/token')),
            isEmpty,
          );
        },
      );
    }

    test('malformed token is rejected without installation', () async {
      await expectLater(
        guarded.adopt(
          guarded.begin(),
          const ProbeHandoff(accessToken: 'not-a-jwt'),
        ),
        throwsA(isA<AuthException>()),
      );
      expect(auth.currentSession?.accessToken, initial);
      expect(provider.requests, isEmpty);
    });

    test('provider rejection is not bypassed by a valid-looking JWT', () async {
      final unaccepted = probeToken(label: 'provider-rejects');
      await expectLater(
        guarded.adopt(guarded.begin(), ProbeHandoff(accessToken: unaccepted)),
        throwsA(isA<AuthException>()),
      );
      expect(auth.currentSession?.accessToken, initial);
    });

    for (final wrongClaim in ['subject', 'session']) {
      test(
        'provider-accepted wrong $wrongClaim cannot match the handoff',
        () async {
          final token = probeToken(
            userId: wrongClaim == 'subject' ? probeUserB : probeUserA,
            sessionId: wrongClaim == 'session' ? probeSessionB : probeSessionA,
          );
          provider.users[token] = probeUser(
            wrongClaim == 'subject' ? probeUserB : probeUserA,
          );
          await expectLater(
            guarded.adopt(guarded.begin(), ProbeHandoff(accessToken: token)),
            throwsA(isA<ProbeRejected>()),
          );
          expect(auth.currentSession?.accessToken, initial);
        },
      );
    }

    test(
      'validated user must agree with the token and handoff subject',
      () async {
        provider.users[rotated] = probeUser(probeUserB);
        await expectLater(
          guarded.adopt(guarded.begin(), ProbeHandoff(accessToken: rotated)),
          throwsA(isA<ProbeRejected>()),
        );
        expect(auth.currentSession?.accessToken, initial);
      },
    );

    test(
      'late validation failure does not install or create an auth event',
      () async {
        final pause = provider.pauseUser(rotated);
        final pending = guarded.adopt(
          guarded.begin(),
          ProbeHandoff(accessToken: rotated),
        );
        final rejection = expectLater(pending, throwsA(isA<AuthException>()));
        await pause.started.future;
        pause.response.complete(
          probeResponse({'msg': 'unavailable'}, status: 503),
        );
        await rejection;
        expect(auth.currentSession?.accessToken, initial);
        expect(guarded.acceptedChanges, 0);
      },
    );

    test(
      'refresh finishing during validation invalidates the old pair',
      () async {
        final validationPause = provider.pauseUser(rotated);
        final pending = guarded.adopt(
          guarded.begin(),
          ProbeHandoff(accessToken: rotated),
        );
        final rejection = expectLater(pending, throwsA(isA<ProbeRejected>()));
        await validationPause.started.future;
        final refreshPause = ProbePause();
        provider.refreshPause = refreshPause;
        final refreshing = auth.refreshSession();
        await refreshPause.started.future;
        final refreshed = probeToken(label: 'concurrent-refresh');
        refreshPause.response.complete(probeResponse(probeSession(refreshed)));
        await refreshing;
        validationPause.response.complete(probeResponse(probeUser(probeUserA)));
        await rejection;
        expect(auth.currentSession?.accessToken, refreshed);
      },
    );

    test(
      'refresh already in flight cannot overwrite the committed pair',
      () async {
        final refreshPause = ProbePause();
        provider.refreshPause = refreshPause;
        final refreshing = auth.refreshSession();
        await refreshPause.started.future;
        await guarded.adopt(
          guarded.begin(),
          ProbeHandoff(accessToken: rotated),
        );
        final lateRefresh = probeToken(label: 'late-refresh');
        refreshPause.response.complete(
          probeResponse(probeSession(lateRefresh)),
        );
        await refreshing;
        expect(auth.currentSession?.accessToken, rotated);
        expect(guarded.acceptedChanges, 1);
        // The provider may still have rotated a refresh token remotely. This VM
        // assertion establishes only local state isolation, not token usability.
      },
    );
  });
}
