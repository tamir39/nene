import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data/auth_repository.dart';
import 'data/profile_api.dart';
import 'data/user_profile.dart';

enum SessionStatus { signedOut, loading, ready, unavailable }

class SessionController extends ChangeNotifier {
  SessionController({
    required AuthRepository auth,
    required ProfileRepository profiles,
  }) : _auth = auth,
       _profiles = profiles {
    _subscription = _auth.changes.listen(
      (_) {
        if (!_locallySignedOut) unawaited(loadProfile());
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
