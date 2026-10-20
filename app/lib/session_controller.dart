import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data/auth_repository.dart';
import 'data/profile_api.dart';
import 'data/user_profile.dart';

enum SessionStatus { signedOut, loading, ready, unavailable }

/// A pending screen request belongs to a session that is no longer active.
class SessionChangedException implements Exception {
  const SessionChangedException();
}

class SessionController extends ChangeNotifier {
  SessionController({
    required AuthRepository auth,
    required ProfileRepository profiles,
  }) : _auth = auth,
       _profiles = profiles {
    _subscription = _auth.changes.listen(
      (_) {
        if (!_locallySignedOut) {
          unawaited(
            status == SessionStatus.ready && profile?.id == _auth.userId
                ? revalidateProfile()
                : loadProfile(),
          );
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_locallySignedOut) return;
        _revision++;
        profile = null;
        status = SessionStatus.unavailable;
        message = 'Your session could not be refreshed. Please try again.';
        _notify();
      },
    );
  }

  final AuthRepository _auth;
  final ProfileRepository _profiles;
  late final StreamSubscription<void> _subscription;
  SessionStatus status = SessionStatus.signedOut;
  UserProfile? profile;
  String? message;
  bool _signingIn = false;
  bool _signingOut = false;
  bool _locallySignedOut = false;
  bool _disposed = false;
  int _revision = 0;
  int _profileRequest = 0;
  int get generation => _revision;

  /// Capture the session before a request, and discard its result after any
  /// session transition. The backend still authorizes each operation.
  Future<T> authorized<T>(
    Future<T> Function(String token) operation, {
    required AppRole role,
  }) async {
    final revision = _revision;
    final userId = _auth.userId;
    final token = _auth.accessToken;
    if (_disposed ||
        _locallySignedOut ||
        status != SessionStatus.ready ||
        userId == null ||
        token == null) {
      throw const SessionChangedException();
    }
    if (profile?.role != role) {
      throw const ApiException(ApiFailure.forbidden);
    }
    try {
      final result = await operation(token);
      if (!_isCurrent(revision, userId)) {
        throw const SessionChangedException();
      }
      return result;
    } on ApiException catch (error) {
      if (!_isCurrent(revision, userId)) {
        throw const SessionChangedException();
      }
      if (error.failure == ApiFailure.unauthorized) {
        await signOut();
        if (!_disposed) {
          message = 'Your session has expired. Please sign in again.';
          _notify();
        }
      }
      rethrow;
    }
  }

  void acceptOwnProfile(UserProfile updated) {
    if (status != SessionStatus.ready ||
        updated.id != profile?.id ||
        updated.role != profile?.role) {
      throw const ApiException(ApiFailure.invalidResponse);
    }
    _profileRequest++;
    profile = updated;
    _notify();
  }

  /// Returning from a keyboard/password manager or refreshing a token for the
  /// same principal must not destroy an in-memory, idempotent creation attempt.
  /// Every API write still verifies its bearer token independently on NestJS.
  Future<void> revalidateProfile() async {
    if (_disposed || _locallySignedOut || status != SessionStatus.ready) return;
    final revision = _revision;
    final request = ++_profileRequest;
    final token = _auth.accessToken;
    final userId = _auth.userId;
    if (token == null || userId == null || userId != profile?.id) {
      await loadProfile();
      return;
    }
    try {
      final loaded = await _profiles.getProfile(token);
      if (!_isCurrent(revision, userId) || request != _profileRequest) return;
      if (loaded.id != userId) {
        throw const ApiException(ApiFailure.invalidResponse);
      }
      if (loaded.role != profile?.role) _revision++;
      profile = loaded;
      _notify();
    } on ApiException catch (error) {
      if (!_isCurrent(revision, userId) || request != _profileRequest) return;
      if (error.failure == ApiFailure.unauthorized) {
        await signOut();
        if (!_disposed) {
          message = 'Your session has expired. Please sign in again.';
          _notify();
        }
      } else if (error.failure == ApiFailure.forbidden ||
          error.failure == ApiFailure.invalidResponse) {
        _revision++;
        profile = null;
        status = SessionStatus.unavailable;
        message =
            'Your profile is not available. Please contact your bank officer.';
        _notify();
      }
      // A transient refresh failure keeps only the already loaded workspace.
      // It grants no new permission and cannot turn a failed write into success.
    } catch (_) {
      // Keep pending work on transient transport failure, as above.
    }
  }

  Future<void> signIn(String email, String password) async {
    if (_signingIn || _signingOut) return;
    final revision = ++_revision;
    _signingIn = true;
    _locallySignedOut = true;
    status = SessionStatus.loading;
    message = null;
    profile = null;
    _notify();
    try {
      await _auth.signIn(email.trim(), password);
      if (!_disposed && revision == _revision && !_signingOut) {
        _locallySignedOut = false;
        await loadProfile();
      }
    } catch (_) {
      if (!_disposed && revision == _revision && !_signingOut) {
        _locallySignedOut = true;
        status = SessionStatus.signedOut;
        message = 'Unable to sign in. Check your details and connection.';
        _notify();
      }
    } finally {
      _signingIn = false;
    }
  }

  Future<void> loadProfile() async {
    if (_disposed || _locallySignedOut) return;
    final revision = ++_revision;
    _profileRequest++;
    final token = _auth.accessToken;
    final userId = _auth.userId;
    profile = null;
    message = null;
    if (token == null || userId == null) {
      status = SessionStatus.signedOut;
      _notify();
      return;
    }
    status = SessionStatus.loading;
    _notify();
    try {
      final loaded = await _profiles.getProfile(token);
      if (!_isCurrent(revision, userId)) return;
      if (loaded.id != userId) {
        throw const ApiException(ApiFailure.invalidResponse);
      }
      profile = loaded;
      status = SessionStatus.ready;
    } on ApiException catch (error) {
      if (!_isCurrent(revision, userId)) return;
      if (error.failure == ApiFailure.unauthorized) {
        await signOut();
        if (_disposed) return;
        message = 'Your session has expired. Please sign in again.';
        _notify();
        return;
      }
      status = SessionStatus.unavailable;
      message = error.failure == ApiFailure.forbidden
          ? 'Your profile is not available. Please contact your bank officer.'
          : 'Your profile could not be loaded. Please try again.';
    } catch (_) {
      if (!_isCurrent(revision, userId)) return;
      status = SessionStatus.unavailable;
      message = 'Your profile could not be loaded. Please try again.';
    }
    _notify();
  }

  Future<void> signOut() async {
    if (_signingOut) return;
    _signingOut = true;
    _locallySignedOut = true;
    _revision++;
    profile = null;
    message = null;
    status = SessionStatus.loading;
    _notify();
    try {
      await _auth.signOut();
    } catch (_) {
      // The UI remains locked even when remote session revocation fails.
      // Session persistence is disabled: app restart drops all local tokens.
    } finally {
      _signingOut = false;
      status = SessionStatus.signedOut;
      _notify();
    }
  }

  bool _isCurrent(int revision, String userId) =>
      !_disposed &&
      !_locallySignedOut &&
      revision == _revision &&
      _auth.userId == userId;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
