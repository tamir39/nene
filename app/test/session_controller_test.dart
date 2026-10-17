import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nene_app/data/profile_api.dart';
import 'package:nene_app/data/user_profile.dart';
import 'package:nene_app/session_controller.dart';

import 'test_doubles.dart';

void main() {
  late FakeAuth auth;
  late FakeProfiles profiles;
  late SessionController controller;

  setUp(() {
    auth = FakeAuth();
    profiles = FakeProfiles();
    controller = SessionController(auth: auth, profiles: profiles);
  });
  tearDown(() async {
    controller.dispose();
    await auth.events.close();
  });

  test('does not use authentication alone as an application role', () async {
    profiles.fetch = (_) async =>
        throw const ApiException(ApiFailure.forbidden);
    await controller.signIn('student@example.test', 'password');
    expect(controller.status, SessionStatus.unavailable);
    expect(controller.profile, isNull);
  });

  test('profile must belong to the current authenticated identity', () async {
    profiles.fetch = (_) async => const UserProfile(
      id: 'another-user',
      email: 'other@example.test',
      displayName: 'Other',
      role: AppRole.officer,
    );
    await controller.signIn('student@example.test', 'password');
    expect(controller.status, SessionStatus.unavailable);
    expect(controller.profile, isNull);
  });

  test('expired session clears protected state and asks for sign-in', () async {
    await controller.signIn('student@example.test', 'password');
    expect(controller.status, SessionStatus.ready);
    profiles.fetch = (_) async =>
        throw const ApiException(ApiFailure.unauthorized);
    await controller.loadProfile();
    expect(controller.status, SessionStatus.signedOut);
    expect(controller.profile, isNull);
    expect(auth.signOutCount, 1);
    expect(controller.message, contains('expired'));
  });

  test(
    'in-flight profile responses cannot restore state after sign-out',
    () async {
      await controller.signIn('student@example.test', 'password');
      final pending = Completer<UserProfile>();
      profiles.fetch = (_) => pending.future;
      final load = controller.loadProfile();
      await controller.signOut();
      pending.complete(demoProfile);
      await load;
      expect(controller.status, SessionStatus.signedOut);
      expect(controller.profile, isNull);
    },
  );

  test('auth stream errors hide profile and recover through retry', () async {
    await controller.signIn('student@example.test', 'password');
    auth.events.addError(Exception('offline'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, SessionStatus.unavailable);
    expect(controller.profile, isNull);
    await controller.loadProfile();
    expect(controller.status, SessionStatus.ready);
  });

  test(
    'failed revocation and failed re-login cannot revive an old session',
    () async {
      await controller.signIn('student@example.test', 'password');
      auth.signOutError = Exception('offline');
      await controller.signOut();
      auth.events.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, SessionStatus.signedOut);
      auth.signInError = Exception('invalid credentials');
      await controller.signIn('student@example.test', 'wrong password');
      auth.events.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, SessionStatus.signedOut);
      expect(controller.profile, isNull);
    },
  );
}
