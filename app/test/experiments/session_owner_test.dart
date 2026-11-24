import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../../../experiments/session_coordinator/session_owner.dart';

// Coordinator tests only. This fake port makes provider completion order
// deterministic; real provider and browser behavior have separate probes.
const userA = '10000000-0000-4000-8000-000000000001';
const userB = '10000000-0000-4000-8000-000000000002';
const sessionA = '20000000-0000-4000-8000-000000000001';
const sessionB = '20000000-0000-4000-8000-000000000002';
final instant = DateTime.utc(2026, 10, 27, 12);

OwnedSession sessionValue(
  String label, {
  String userId = userA,
  String sessionId = sessionA,
  DateTime? expiresAt,
}) => OwnedSession(
  pair: AuthPair(accessToken: 'access-$label', refreshToken: 'refresh-$label'),
  userId: userId,
  sessionId: sessionId,
  expiresAt: expiresAt ?? instant.add(const Duration(hours: 1)),
);

class FakePort implements AuthPort {
  final sessions = <String, OwnedSession>{};
  final calls = <String>[];
  late OwnedSession loginSession;
  late OwnedSession refreshSession;
  Future<AuthPair> Function(String, String)? onSignIn;
  Future<AuthPair> Function(OwnedSession)? onRefresh;
  Future<OwnedSession> Function(AuthPair)? onValidate;
  Future<void> Function(OwnedSession)? onSignOut;

  OwnedSession remember(OwnedSession value) {
    sessions[value.pair.accessToken] = value;
    return value;
  }

  @override
  Future<AuthPair> signIn(String email, String password) async {
    calls.add('sign-in');
    return onSignIn?.call(email, password) ?? loginSession.pair;
  }

  @override
  Future<AuthPair> refresh(OwnedSession current) async {
    calls.add('refresh:${current.pair.refreshToken}');
    return onRefresh?.call(current) ?? refreshSession.pair;
  }

  @override
  Future<OwnedSession> validate(AuthPair pair) async {
    calls.add('validate:${pair.accessToken}');
    if (onValidate != null) return onValidate!(pair);
    final value = sessions[pair.accessToken];
    // Fixture lookup only: Supabase's /user authenticates the access token;
    // trusted response provenance supplies its accompanying refresh token.
    if (value == null || value.pair.refreshToken != pair.refreshToken) {
      throw StateError('Invalid synthetic provider response');
    }
    return value;
  }

  @override
  Future<void> signOut(OwnedSession current) async {
    calls.add('sign-out:${current.pair.accessToken}');
    await onSignOut?.call(current);
  }
}

HandoffBinding binding({
  String requestId = 'owned-request',
  String purpose = 'enroll',
  int securityRevision = 1,
}) => HandoffBinding(
  requestId: requestId,
  purpose: purpose,
  securityRevision: securityRevision,
);

Future<void> rejected(Future<void> operation) =>
    expectLater(operation, throwsA(anything));

Future<void> nextTurn() => Future<void>.delayed(Duration.zero);

void main() {
  late FakePort port;
  late SessionOwner owner;
  late OwnedSession initial;
  late OwnedSession refreshed;
  late OwnedSession upgraded;
  late OwnedSession other;

  setUp(() async {
    port = FakePort();
    initial = port.remember(sessionValue('initial'));
    refreshed = port.remember(sessionValue('refreshed'));
    upgraded = port.remember(sessionValue('upgraded'));
    other = port.remember(
      sessionValue('other', userId: userB, sessionId: sessionB),
    );
    port.loginSession = initial;
    port.refreshSession = refreshed;
    owner = SessionOwner(port, clock: () => instant);
    await owner.signIn('synthetic-a@example.invalid', 'synthetic-only');
    port.calls.clear();
  });

  tearDown(() => owner.dispose());

  test('owned snapshot is not a mutable provider session getter', () async {
    port.loginSession = other;
    port.sessions[initial.pair.accessToken] = other;
    expect(owner.session?.userId, userA);
    expect(owner.session?.sessionId, sessionA);
    expect(owner.session?.pair.accessToken, initial.pair.accessToken);
    expect(port.calls, isEmpty);
  });

  test(
    'refresh adopts a validated pair for the same user and session',
    () async {
      await owner.refresh();
      expect(owner.session?.pair.accessToken, refreshed.pair.accessToken);
      expect(owner.session?.userId, userA);
      expect(owner.session?.sessionId, sessionA);
      expect(port.calls.first, 'refresh:${initial.pair.refreshToken}');
    },
  );

  test(
    'handoff waits for a refresh and dispatches with its new pair',
    () async {
      final started = Completer<void>();
      final reply = Completer<AuthPair>();
      port.onRefresh = (current) {
        started.complete();
        return reply.future;
      };
      final refreshing = owner.refresh();
      await started.future;
      final seen = <String>[];
      final request = binding();
      final handoff = owner.exchange(request, (current) async {
        seen.add(current.pair.accessToken);
        return HandoffReply(pair: upgraded.pair, binding: request);
      });
      await nextTurn();
      expect(seen, isEmpty);
      reply.complete(refreshed.pair);
      await refreshing;
      await handoff;
      expect(seen, [refreshed.pair.accessToken]);
      expect(owner.session?.pair.accessToken, upgraded.pair.accessToken);
    },
  );

  test('refresh waits until handoff validation and adoption finish', () async {
    final started = Completer<void>();
    final reply = Completer<HandoffReply>();
    final validationStarted = Completer<void>();
    final validation = Completer<OwnedSession>();
    port.onValidate = (pair) {
      if (pair.accessToken == upgraded.pair.accessToken) {
        validationStarted.complete();
        return validation.future;
      }
      return Future.value(port.sessions[pair.accessToken]!);
    };
    final request = binding();
    final handoff = owner.exchange(request, (current) {
      started.complete();
      return reply.future;
    });
    await started.future;
    final refreshing = owner.refresh();
    await nextTurn();
    expect(port.calls.where((entry) => entry.startsWith('refresh:')), isEmpty);
    reply.complete(HandoffReply(pair: upgraded.pair, binding: request));
    await validationStarted.future;
    await nextTurn();
    expect(port.calls.where((entry) => entry.startsWith('refresh:')), isEmpty);
    expect(owner.session?.pair.accessToken, initial.pair.accessToken);
    validation.complete(upgraded);
    await handoff;
    await refreshing;
    expect(port.calls, contains('refresh:${upgraded.pair.refreshToken}'));
    expect(owner.session?.pair.accessToken, refreshed.pair.accessToken);
  });

  test(
    'duplicate pending handoff never dispatches a second exchange',
    () async {
      final started = Completer<void>();
      final reply = Completer<HandoffReply>();
      final request = binding();
      var dispatches = 0;
      final first = owner.exchange(request, (_) {
        dispatches++;
        started.complete();
        return reply.future;
      });
      await started.future;
      final duplicate = rejected(
        owner.exchange(binding(), (_) async {
          dispatches++;
          return HandoffReply(pair: refreshed.pair, binding: binding());
        }),
      );
      reply.complete(HandoffReply(pair: upgraded.pair, binding: request));
      await first;
      await duplicate;
      expect(dispatches, 1);
      expect(owner.session?.pair.accessToken, upgraded.pair.accessToken);
    },
  );

  test('completed handoff binding is single-use for its generation', () async {
    final request = binding();
    await owner.exchange(
      request,
      (_) async => HandoffReply(pair: upgraded.pair, binding: request),
    );
    var repeated = false;
    await rejected(
      owner.exchange(binding(), (_) async {
        repeated = true;
        return HandoffReply(pair: refreshed.pair, binding: binding());
      }),
    );
    expect(repeated, isFalse);
    expect(owner.session?.pair.accessToken, upgraded.pair.accessToken);
  });

  test(
    'concurrent refreshes never dispatch provider mutations together',
    () async {
      var active = 0;
      var maximum = 0;
      final firstStarted = Completer<void>();
      final firstReply = Completer<AuthPair>();
      var count = 0;
      port.onRefresh = (current) async {
        active++;
        if (active > maximum) maximum = active;
        count++;
        try {
          if (count == 1) {
            firstStarted.complete();
            return await firstReply.future;
          }
          expect(current.pair.accessToken, refreshed.pair.accessToken);
          return upgraded.pair;
        } finally {
          active--;
        }
      };
      final first = owner.refresh();
      await firstStarted.future;
      final second = owner.refresh();
      await nextTurn();
      expect(count, 1);
      firstReply.complete(refreshed.pair);
      await Future.wait([first, second]);
      expect(maximum, 1);
    },
  );

  test('logout clears immediately and rejects a late handoff reply', () async {
    final started = Completer<void>();
    final reply = Completer<HandoffReply>();
    final request = binding();
    final handoff = owner.exchange(request, (current) {
      started.complete();
      return reply.future;
    });
    final rejection = rejected(handoff);
    await started.future;
    final generation = owner.generation;
    final logout = owner.signOut();
    expect(owner.session, isNull);
    expect(owner.generation, greaterThan(generation));
    reply.complete(HandoffReply(pair: upgraded.pair, binding: request));
    await rejection;
    await logout;
    expect(owner.session, isNull);
    expect(port.calls, contains('sign-out:${initial.pair.accessToken}'));
  });

  test('logout clears immediately and rejects a late refresh reply', () async {
    final started = Completer<void>();
    final reply = Completer<AuthPair>();
    port.onRefresh = (current) {
      started.complete();
      return reply.future;
    };
    final rejection = rejected(owner.refresh());
    await started.future;
    final logout = owner.signOut();
    expect(owner.session, isNull);
    reply.complete(refreshed.pair);
    await rejection;
    await logout;
    expect(owner.session, isNull);
  });

  test('queued logout revokes its old session before a newer login', () async {
    final refreshStarted = Completer<void>();
    final refreshReply = Completer<AuthPair>();
    port.onRefresh = (_) {
      refreshStarted.complete();
      return refreshReply.future;
    };
    final refreshRejection = rejected(owner.refresh());
    await refreshStarted.future;
    final logoutStarted = Completer<void>();
    final logoutReply = Completer<void>();
    port.onSignOut = (captured) {
      expect(captured.pair.accessToken, initial.pair.accessToken);
      expect(captured.sessionId, sessionA);
      logoutStarted.complete();
      return logoutReply.future;
    };
    final logout = owner.signOut();
    expect(owner.session, isNull);
    port.loginSession = other;
    final login = owner.signIn('synthetic-b@example.invalid', 'synthetic-only');
    refreshReply.complete(refreshed.pair);
    await refreshRejection;
    await logoutStarted.future;
    expect(port.calls, isNot(contains('sign-in')));
    expect(owner.session, isNull);
    logoutReply.complete();
    await logout;
    await login;
    expect(owner.session?.userId, userB);
    expect(owner.session?.sessionId, sessionB);
    expect(port.calls.where((entry) => entry.startsWith('sign-out:')), [
      'sign-out:${initial.pair.accessToken}',
    ]);
    expect(
      port.calls.indexOf('sign-out:${initial.pair.accessToken}'),
      lessThan(port.calls.indexOf('sign-in')),
    );
  });

  for (final lateFailure in [false, true]) {
    test(
      'logout timeout and late ${lateFailure ? 'failure' : 'success'} preserve newer login',
      () async {
        owner.dispose();
        owner = SessionOwner(
          port,
          clock: () => instant,
          timeout: const Duration(milliseconds: 40),
        );
        await owner.signIn('synthetic-a@example.invalid', 'synthetic-only');
        port.calls.clear();
        final logoutStarted = Completer<void>();
        final logoutReply = Completer<void>();
        port.onSignOut = (captured) {
          expect(captured.pair.accessToken, initial.pair.accessToken);
          logoutStarted.complete();
          return logoutReply.future;
        };
        final logoutRejection = rejected(owner.signOut());
        expect(owner.session, isNull);
        await logoutStarted.future;
        port.loginSession = other;
        final login = owner.signIn(
          'synthetic-b@example.invalid',
          'synthetic-only',
        );
        final loginGeneration = owner.generation;
        await logoutRejection;
        await login;
        expect(owner.session?.userId, userB);
        expect(owner.generation, loginGeneration);
        if (lateFailure) {
          logoutReply.completeError(
            StateError('Late synthetic revoke failure'),
          );
        } else {
          logoutReply.complete();
        }
        await nextTurn();
        expect(owner.session?.userId, userB);
        expect(owner.session?.sessionId, sessionB);
        expect(owner.generation, loginGeneration);
        expect(port.calls.where((entry) => entry.startsWith('sign-out:')), [
          'sign-out:${initial.pair.accessToken}',
        ]);
      },
    );
  }

  test(
    'account switch defeats an older handoff and validates new login',
    () async {
      final started = Completer<void>();
      final reply = Completer<HandoffReply>();
      final request = binding();
      final rejection = rejected(
        owner.exchange(request, (current) {
          started.complete();
          return reply.future;
        }),
      );
      await started.future;
      port.loginSession = other;
      final login = owner.signIn(
        'synthetic-b@example.invalid',
        'synthetic-only',
      );
      expect(owner.session, isNull);
      reply.complete(HandoffReply(pair: upgraded.pair, binding: request));
      await rejection;
      await login;
      expect(owner.session?.userId, userB);
      expect(owner.session?.sessionId, sessionB);
    },
  );

  test('later password login defeats a delayed earlier login', () async {
    final started = Completer<void>();
    final reply = Completer<AuthPair>();
    var count = 0;
    port.onSignIn = (_, _) {
      count++;
      if (count == 1) {
        started.complete();
        return reply.future;
      }
      return Future.value(other.pair);
    };
    final earlier = rejected(
      owner.signIn('synthetic-a@example.invalid', 'synthetic-only'),
    );
    await started.future;
    final later = owner.signIn('synthetic-b@example.invalid', 'synthetic-only');
    expect(owner.session, isNull);
    reply.complete(initial.pair);
    await earlier;
    await later;
    expect(owner.session?.userId, userB);
  });

  test('logout during candidate validation prevents adoption', () async {
    final started = Completer<void>();
    final validation = Completer<OwnedSession>();
    port.onValidate = (pair) {
      if (pair.accessToken == upgraded.pair.accessToken) {
        started.complete();
        return validation.future;
      }
      return Future.value(port.sessions[pair.accessToken]!);
    };
    final request = binding();
    final rejection = rejected(
      owner.exchange(
        request,
        (_) async => HandoffReply(pair: upgraded.pair, binding: request),
      ),
    );
    await started.future;
    final logout = owner.signOut();
    validation.complete(upgraded);
    await rejection;
    await logout;
    expect(owner.session, isNull);
  });

  test(
    'unknown rotation timeout clears state and rejects queued mutation',
    () async {
      owner.dispose();
      owner = SessionOwner(
        port,
        clock: () => instant,
        timeout: const Duration(milliseconds: 40),
      );
      await owner.signIn('synthetic-a@example.invalid', 'synthetic-only');
      final started = Completer<void>();
      final reply = Completer<AuthPair>();
      port.onRefresh = (_) {
        started.complete();
        return reply.future;
      };
      final refreshRejection = rejected(owner.refresh());
      await started.future;
      var dispatches = 0;
      final request = binding();
      final queuedRejection = rejected(
        owner.exchange(request, (_) async {
          dispatches++;
          return HandoffReply(pair: upgraded.pair, binding: request);
        }),
      );
      await refreshRejection;
      await queuedRejection;
      expect(owner.session, isNull);
      expect(dispatches, 0);
      port.loginSession = other;
      await owner.signIn('synthetic-b@example.invalid', 'synthetic-only');
      expect(owner.session?.userId, userB);
      reply.complete(refreshed.pair);
      await nextTurn();
      expect(owner.session?.userId, userB);
    },
  );

  test('failed provider mutation requires a new login', () async {
    port.onRefresh = (_) async => throw StateError('Unknown synthetic outcome');
    await rejected(owner.refresh());
    expect(owner.session, isNull);
    port.calls.clear();
    await rejected(owner.refresh());
    expect(port.calls, isEmpty);
    port.loginSession = other;
    await owner.signIn('synthetic-b@example.invalid', 'synthetic-only');
    expect(owner.session?.userId, userB);
  });

  for (final wrong in <String, OwnedSession>{
    'customer': sessionValue('wrong-customer', userId: userB),
    'session': sessionValue('wrong-session', sessionId: sessionB),
    'expired': sessionValue('expired', expiresAt: instant),
    'near-expiry': sessionValue(
      'near-expiry',
      expiresAt: instant.add(const Duration(seconds: 10)),
    ),
  }.entries) {
    test('refresh rejects ${wrong.key} candidate and fails closed', () async {
      port.refreshSession = port.remember(wrong.value);
      await rejected(owner.refresh());
      expect(owner.session, isNull);
    });
    test('handoff rejects ${wrong.key} candidate and fails closed', () async {
      port.remember(wrong.value);
      final request = binding();
      await rejected(
        owner.exchange(
          request,
          (_) async => HandoffReply(pair: wrong.value.pair, binding: request),
        ),
      );
      expect(owner.session, isNull);
    });
  }

  for (final mismatch in <String, HandoffBinding>{
    'request': binding(requestId: 'different-request'),
    'purpose': binding(purpose: 'payment'),
    'revision': binding(securityRevision: 0),
  }.entries) {
    test('handoff rejects mismatched ${mismatch.key}', () async {
      await rejected(
        owner.exchange(
          binding(),
          (_) async =>
              HandoffReply(pair: upgraded.pair, binding: mismatch.value),
        ),
      );
      expect(owner.session, isNull);
    });
  }

  test('malformed provider pair is rejected without adoption', () async {
    port.onRefresh = (_) async => AuthPair(
      accessToken: 'not-a-known-provider-token',
      refreshToken: 'synthetic-unknown-refresh',
    );
    await rejected(owner.refresh());
    expect(owner.session, isNull);
  });

  test(
    'validation failure after successful mutation does not retain old pair',
    () async {
      port.onValidate = (_) async => throw StateError('Validation unavailable');
      await rejected(owner.refresh());
      expect(owner.session, isNull);
    },
  );

  test(
    'validation cannot substitute a different pair for the supplied one',
    () async {
      port.onValidate = (_) async => upgraded;
      await rejected(owner.refresh());
      expect(owner.session, isNull);
    },
  );

  test('disposing with a pending reply prevents installation', () async {
    final started = Completer<void>();
    final reply = Completer<AuthPair>();
    port.onRefresh = (_) {
      started.complete();
      return reply.future;
    };
    final rejection = rejected(owner.refresh());
    await started.future;
    owner.dispose();
    reply.complete(refreshed.pair);
    await rejection;
    expect(owner.session, isNull);
    await rejected(owner.refresh());
  });
}
