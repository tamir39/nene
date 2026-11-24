import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'session_owner.dart';

/// App entry point uses this owner; the legacy adapter is retained for SDK
/// regression fixtures only and is never constructed by main.
class OwnedAuthRepository implements AuthRepository {
  OwnedAuthRepository(this.owner) {
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      final session = owner.session;
      if (session != null &&
          session.expiresAt.difference(DateTime.now()).inMinutes < 3 &&
          !_refreshing) {
        _refreshing = true;
        owner
            .refresh()
            .catchError((Object _) {})
            .whenComplete(() => _refreshing = false);
      }
    });
  }
  final SessionOwner owner;
  late final Timer _timer;
  bool _refreshing = false;
  @override
  String? get userId => owner.session?.userId;
  @override
  String? get accessToken => owner.session?.pair.accessToken;
  @override
  Stream<void> get changes => owner.changes;
  @override
  Future<void> signIn(String email, String password) =>
      owner.signIn(email, password);
  @override
  Future<void> signOut() => owner.signOut();
  void dispose() {
    _timer.cancel();
    owner.dispose();
  }
}

abstract interface class AuthRepository {
  String? get userId;
  String? get accessToken;
  Stream<void> get changes;
  Future<void> signIn(String email, String password);
  Future<void> signOut();
}

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);
  final SupabaseClient _client;

  @override
  String? get userId => _client.auth.currentUser?.id;

  @override
  String? get accessToken => _client.auth.currentSession?.accessToken;

  @override
  Stream<void> get changes => _client.auth.onAuthStateChange.map((_) {});

  @override
  Future<void> signIn(String email, String password) async {
    await _client.auth.signInWithPassword(email: email, password: password);
  }

  @override
  Future<void> signOut() => _client.auth
      .signOut(scope: SignOutScope.local)
      .timeout(const Duration(seconds: 15));
}
