import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nene_app/data/identity_repository.dart';
import 'package:nene_app/data/profile_api.dart';
import 'package:nene_app/data/reference_photo_source.dart';
import 'package:nene_app/data/user_profile.dart';
import 'package:nene_app/identity_controller.dart';
import 'package:nene_app/session_controller.dart';

import 'identity_test_doubles.dart';
import 'test_doubles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAuth auth;
  late FakeProfiles profiles;
  late FakeIdentity repository;
  late FakePhotos photos;
  late SessionController session;
  IdentityController? flow;

  Future<IdentityController> start({bool officer = false}) async {
    if (officer) {
      profiles.fetch = (_) async => officerProfile;
      repository.value = IdentitySummary.fromJson(
        identityJson(customerId: 'customer-id'),
      );
    }
    await session.signIn('demo@example.test', 'synthetic-password');
    final controller = flow = IdentityController(
      session: session,
      repository: repository,
      photos: photos,
      customerId: officer ? 'customer-id' : null,
    );
    await controller.load();
    return controller;
  }

  setUp(() {
    auth = FakeAuth();
    profiles = FakeProfiles();
    repository = FakeIdentity();
    photos = FakePhotos();
    session = SessionController(auth: auth, profiles: profiles);
  });
  tearDown(() async {
    flow?.dispose();
    flow = null;
    session.dispose();
    await auth.events.close();
  });

  test(
    'customer acknowledges, captures, uploads then submits a private reference',
    () async {
      final c = await start();
      await c.start(acknowledged: false);
      expect(repository.startKeys, isEmpty);
      await c.start(acknowledged: true);
      expect(c.summary!.status, 'draft');
      await c.capture();
      expect(c.captured, isNotNull);
      await c.submit();
      expect(repository.submits, 0);
      await c.upload();
      expect(c.captured, isNull);
      expect(c.evidence, isNotNull);
      await c.submit();
      expect(c.summary!.label, 'Awaiting officer review');
      await c.review(accept: true, associationConfirmed: true);
      expect(repository.reviewActions, isEmpty);
    },
  );

  test(
    'a lost upload reply is reconciled without posting another upload',
    () async {
      final c = await start();
      await c.start(acknowledged: true);
      await c.capture();
      repository.uploadAction = (_) async {
        repository.set('draft', 2);
        throw const ApiException(ApiFailure.unavailable);
      };
      await c.upload();
      expect(c.mustCheckStatus, isTrue);
      await c.upload();
      expect(repository.uploadKeys, hasLength(1));
      await c.load();
      expect(c.summary!.version, 2);
      expect(c.captured, isNull);
      expect(c.canRetry, isFalse);
      await c.submit();
      expect(repository.submits, 1);
    },
  );

  test(
    'unknown unchanged outcome retries with original idempotency key after status check',
    () async {
      final c = await start();
      repository.startAction = (_) async =>
          throw const ApiException(ApiFailure.unavailable);
      await c.start(acknowledged: true);
      await c.retry();
      expect(repository.startKeys, hasLength(1));
      await c.load();
      expect(c.canRetry, isTrue);
      repository.startAction = null;
      await c.retry();
      expect(repository.startKeys[1], repository.startKeys[0]);
      expect(c.summary!.status, 'draft');
    },
  );

  test(
    'officer acceptance needs a loaded photo and explicit association confirmation',
    () async {
      final c = await start(officer: true);
      repository.set('submitted', 3);
      repository.preview = () async =>
          throw const ApiException(ApiFailure.unavailable);
      await c.load();
      await c.review(accept: true, associationConfirmed: true);
      expect(repository.reviewActions, isEmpty);
      repository.preview = null;
      await c.load();
      await c.review(accept: true, associationConfirmed: false);
      expect(repository.reviewActions, isEmpty);
      await c.review(accept: true, associationConfirmed: true);
      expect(repository.acknowledgedAssociation, isTrue);
      expect(c.summary!.status, 'reference_accepted');
    },
  );

  test(
    'correction requires a useful reason and does not fabricate verification',
    () async {
      final c = await start(officer: true);
      repository.set('submitted', 3);
      await c.load();
      await c.review(accept: false, associationConfirmed: false, reason: 'bad');
      expect(repository.reviewActions, isEmpty);
      await c.review(
        accept: false,
        associationConfirmed: false,
        reason: 'Please provide a clearer photo.',
      );
      expect(repository.reviewActions, ['request_changes']);
      expect(c.summary!.status, 'needs_changes');
      expect(repository.acknowledgedAssociation, isFalse);
    },
  );

  test(
    'refresh after a name change removes the old acceptance banner',
    () async {
      final c = await start(officer: true);
      repository.set('submitted', 3);
      await c.load();
      await c.review(accept: true, associationConfirmed: true);
      expect(c.message, contains('Reference accepted'));
      repository.set('needs_changes', 5);
      await c.load();
      expect(c.summary!.status, 'needs_changes');
      expect(c.message, isNull);
    },
  );

  test(
    'review retry reports newer current state rather than the prior intended acceptance',
    () async {
      final c = await start(officer: true);
      repository.set('submitted', 3);
      await c.load();
      repository.reviewAction = (_) async =>
          throw const ApiException(ApiFailure.unavailable);
      await c.review(accept: true, associationConfirmed: true);
      await c.load();
      expect(c.canRetry, isTrue);
      repository.reviewAction = (_) async => repository.set('needs_changes', 5);
      await c.retry();
      expect(c.summary!.status, 'needs_changes');
      expect(c.message, contains('Correction requested'));
      expect(c.message, isNot(contains('Reference accepted')));
    },
  );

  test(
    'photo cancellation preserves the previous capture and permission errors are recoverable',
    () async {
      final c = await start();
      await c.start(acknowledged: true);
      await c.capture();
      final original = c.captured;
      photos.pick = () async => null;
      await c.capture();
      expect(c.captured, same(original));
      photos.pick = () async =>
          throw const PhotoCaptureException('Camera permission denied.');
      await c.capture();
      expect(c.error, contains('permission denied'));
      expect(c.capturing, isFalse);
    },
  );

  test('logout clears photos and discards late camera completion', () async {
    final c = await start();
    await c.start(acknowledged: true);
    final pending = Completer<ReferencePhoto?>();
    photos.pick = () => pending.future;
    final capture = c.capture();
    await session.signOut();
    pending.complete(ReferencePhoto(referenceFixture, 'image/png'));
    await capture;
    expect(c.captured, isNull);
    expect(c.summary, isNull);
  });

  test(
    'same user token refresh preserves capture; confirmed name change clears it',
    () async {
      final c = await start();
      await c.start(acknowledged: true);
      await c.capture();
      await session.revalidateProfile();
      expect(c.captured, isNotNull);
      profiles.fetch = (_) async => const UserProfile(
        id: 'user-id',
        email: 'student@example.test',
        displayName: 'Corrected Student',
        role: AppRole.customer,
      );
      await session.revalidateProfile();
      expect(c.captured, isNull);
      expect(c.summary, isNull);
      expect(c.mustCheckStatus, isTrue);
    },
  );

  test(
    'expired references have no preview and may start a new draft',
    () async {
      final c = await start();
      repository.set('needs_changes', 5, expired: true);
      await c.load();
      expect(c.evidence, isNull);
      expect(c.summary!.label, 'Reference expired');
      await c.start(acknowledged: true);
      expect(c.summary!.status, 'draft');
    },
  );

  test(
    'a stale version discards the pending action and requires status refresh',
    () async {
      final c = await start();
      await c.start(acknowledged: true);
      await c.capture();
      repository.uploadAction = (_) async =>
          throw const ApiException(ApiFailure.conflict);
      await c.upload();
      expect(c.mustCheckStatus, isTrue);
      expect(c.canRetry, isFalse);
      repository.set('needs_changes', 8);
      await c.load();
      expect(c.captured, isNull);
      expect(c.summary!.status, 'needs_changes');
    },
  );

  test(
    'failed status and wrong-customer response never become Not started',
    () async {
      final c = await start();
      repository.fetch = () async =>
          throw const ApiException(ApiFailure.unavailable);
      await c.load();
      expect(c.mustCheckStatus, isTrue);
      repository.fetch = () async =>
          IdentitySummary.fromJson(identityJson(customerId: 'someone-else'));
      await c.load();
      expect(c.summary!.customerId, 'user-id');
      expect(c.mustCheckStatus, isTrue);
    },
  );
}
