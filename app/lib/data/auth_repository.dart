import 'package:supabase_flutter/supabase_flutter.dart';

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
