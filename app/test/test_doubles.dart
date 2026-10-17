import 'dart:async';

import 'package:nene_app/data/auth_repository.dart';
import 'package:nene_app/data/profile_api.dart';
import 'package:nene_app/data/user_profile.dart';

const demoProfile = UserProfile(
  id: 'user-id',
  email: 'student@example.test',
  displayName: 'Demo Student',
  role: AppRole.customer,
);

class FakeAuth implements AuthRepository {
  final events = StreamController<void>.broadcast();
  @override
  String? userId;
  @override
  String? accessToken;
  int signInCount = 0;
  int signOutCount = 0;
  Object? signInError;
  Object? signOutError;

  @override
  Stream<void> get changes => events.stream;

  @override
  Future<void> signIn(String email, String password) async {
    signInCount++;
    if (signInError != null) throw signInError!;
    userId = 'user-id';
    accessToken = 'test-token';
    events.add(null);
  }

  @override
  Future<void> signOut() async {
    signOutCount++;
    if (signOutError != null) throw signOutError!;
    userId = null;
    accessToken = null;
    events.add(null);
  }
}

class FakeProfiles implements ProfileRepository {
  Future<UserProfile> Function(String) fetch = (_) async => demoProfile;

  @override
  Future<UserProfile> getProfile(String accessToken) => fetch(accessToken);
}
