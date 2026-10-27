// Isolated candidate, not imported by app/lib. Supabase remains the Auth
// authority; this owner controls only local credentials and mutation ordering.
import 'dart:async';

class AuthPair {
  const AuthPair({required this.accessToken, required this.refreshToken});
  final String accessToken;
  final String refreshToken;
}

class OwnedSession {
  const OwnedSession({
    required this.pair,
    required this.userId,
    required this.sessionId,
    required this.expiresAt,
  });
  final AuthPair pair;
  final String userId;
  final String sessionId;
  final DateTime expiresAt;
}

/// Every call receives explicit credentials. Implementations must not read a
/// shared SDK session, subscribe to Auth broadcasts, persist or emit tokens.
abstract interface class AuthPort {
  Future<AuthPair> signIn(String email, String password);
  Future<AuthPair> refresh(OwnedSession session);
  Future<OwnedSession> validate(AuthPair pair);
  Future<void> signOut(OwnedSession session);
}

class HandoffBinding {
  const HandoffBinding({
    required this.requestId,
    required this.purpose,
    required this.securityRevision,
  });
  final String requestId;
  final String purpose;
  final int securityRevision;

  @override
  bool operator ==(Object other) =>
      other is HandoffBinding &&
      requestId == other.requestId &&
      purpose == other.purpose &&
      securityRevision == other.securityRevision;

  @override
  int get hashCode => Object.hash(requestId, purpose, securityRevision);
}

class HandoffReply {
  const HandoffReply({required this.pair, required this.binding});
  final AuthPair pair;
  final HandoffBinding binding;
}

class SessionCoordinationException implements Exception {
  const SessionCoordinationException();
}

/// Per-tab memory ownership. No SDK mutable session or broadcast is a source of
/// truth. The serialized lease covers the provider call AND validation/adoption.
class SessionOwner {
  SessionOwner(
    this._port, {
    this.timeout = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (timeout <= Duration.zero) throw ArgumentError('Invalid timeout.');
  }

  final AuthPort _port;
  final Duration timeout;
  final DateTime Function() _clock;
  final _changes = StreamController<void>.broadcast();
  final _handoffs = <HandoffBinding>{};
  Future<void> _tail = Future<void>.value();
  OwnedSession? _session;
  int _generation = 0;
  bool _disposed = false;

  OwnedSession? get session => _session;
  int get generation => _generation;
  Stream<void> get changes => _changes.stream;

  void _clear() {
    _generation++;
    _session = null;
    _handoffs.clear();
    if (!_disposed) _changes.add(null);
  }

  void _current(int generation) {
    if (_disposed || generation != _generation) {
      throw const SessionCoordinationException();
    }
  }

  OwnedSession _owned(int generation, OwnedSession origin) {
    _current(generation);
    final latest = _session;
    if (latest == null ||
        latest.userId != origin.userId ||
        latest.sessionId != origin.sessionId) {
      throw const SessionCoordinationException();
    }
    return latest;
  }

  Future<OwnedSession> _validated(AuthPair pair) async {
    if (pair.accessToken.isEmpty || pair.refreshToken.isEmpty) {
      throw const SessionCoordinationException();
    }
    final verified = await _port.validate(pair);
    if (verified.pair.accessToken != pair.accessToken ||
        verified.pair.refreshToken != pair.refreshToken ||
        verified.userId.isEmpty ||
        verified.sessionId.isEmpty ||
        !verified.expiresAt.isAfter(
          _clock().add(const Duration(seconds: 60)),
        )) {
      throw const SessionCoordinationException();
    }
    return verified;
  }

  // The queue itself never throws, so an older failed task cannot poison a
  // later explicit login. Timeout invalidates its lease before the queue moves.
  Future<void> _enqueue(int generation, Future<void> Function() work) {
    final result = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        _current(generation);
        await work().timeout(timeout);
        _current(generation);
        result.complete();
      } catch (_) {
        if (!_disposed && generation == _generation) _clear();
        result.completeError(const SessionCoordinationException());
      }
    });
    return result.future;
  }

  Future<void> signIn(String email, String password) {
    if (_disposed) return Future.error(const SessionCoordinationException());
    _clear();
    final generation = _generation;
    return _enqueue(generation, () async {
      final pair = await _port.signIn(email, password);
      _current(generation);
      final verified = await _validated(pair);
      _current(generation);
      _session = verified;
      _changes.add(null);
    });
  }

  Future<void> refresh() {
    final origin = _session;
    if (_disposed || origin == null) {
      return Future.error(const SessionCoordinationException());
    }
    final generation = _generation;
    return _enqueue(generation, () async {
      final pair = await _port.refresh(_owned(generation, origin));
      _current(generation);
      final verified = await _validated(pair);
      _owned(generation, origin);
      _sameOrigin(verified, origin);
      _session = verified;
      _changes.add(null);
    });
  }

  Future<void> exchange(
    HandoffBinding binding,
    Future<HandoffReply> Function(OwnedSession) perform,
  ) {
    final origin = _session;
    if (_disposed ||
        origin == null ||
        binding.requestId.isEmpty ||
        binding.requestId.length > 128 ||
        binding.purpose.isEmpty ||
        binding.purpose.length > 32 ||
        binding.securityRevision < 0 ||
        !_handoffs.add(binding)) {
      return Future.error(const SessionCoordinationException());
    }
    final generation = _generation;
    return _enqueue(generation, () async {
      // Dispatch starts only after acquiring the same lease used by refresh.
      final reply = await perform(_owned(generation, origin));
      _current(generation);
      if (reply.binding != binding) throw const SessionCoordinationException();
      final verified = await _validated(reply.pair);
      _owned(generation, origin);
      _sameOrigin(verified, origin);
      _session = verified;
      _changes.add(null);
    });
  }

  void _sameOrigin(OwnedSession candidate, OwnedSession origin) {
    if (candidate.userId != origin.userId ||
        candidate.sessionId != origin.sessionId) {
      throw const SessionCoordinationException();
    }
  }

  Future<void> signOut() {
    if (_disposed) return Future.error(const SessionCoordinationException());
    final captured = _session;
    _clear(); // UI authority ends immediately, even with a request in flight.
    if (captured == null) return Future.value();
    final result = Completer<void>();
    // Explicit logout still attempts revocation if a newer login is queued.
    // Only the captured session is sent; completion/failure never changes the
    // owner, including when this request finishes after its deadline.
    _tail = _tail.then((_) async {
      try {
        await _port.signOut(captured).timeout(timeout);
        result.complete();
      } catch (_) {
        result.completeError(const SessionCoordinationException());
      }
    });
    return result.future;
  }

  void dispose() {
    if (_disposed) return;
    _clear();
    _disposed = true;
    unawaited(_changes.close());
  }
}
