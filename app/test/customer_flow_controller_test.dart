import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nene_app/customer_flow_controller.dart';
import 'package:nene_app/data/banking_repository.dart';
import 'package:nene_app/data/profile_api.dart';
import 'package:nene_app/data/user_profile.dart';
import 'package:nene_app/session_controller.dart';

import 'banking_api_test.dart' show creationDraft;
import 'test_doubles.dart';

void main() {
  late FakeAuth auth;
  late FakeProfiles profiles;
  late FakeBanking repository;
  late SessionController session;
  CustomerFlowController? flow;

  Future<CustomerFlowController> start({bool officer = false}) async {
    if (officer) profiles.fetch = (_) async => officerProfile;
    await session.signIn('demo@example.test', 'synthetic-password');
    return flow = CustomerFlowController(
      session: session,
      repository: repository,
    );
  }

  setUp(() {
    auth = FakeAuth();
    profiles = FakeProfiles();
    repository = FakeBanking();
    session = SessionController(auth: auth, profiles: profiles);
    flow = null;
  });
  tearDown(() async {
    flow?.dispose();
    session.dispose();
    await auth.events.close();
  });

  test(
    'confirmed duplicate email permits correction; generic conflict does not',
    () async {
      final controller = await start(officer: true);
      repository.create = (_, _) async =>
          throw const ApiException(ApiFailure.conflict);
      await controller.createCustomer(creationDraft);
      expect(controller.canCorrectCreation, isFalse);
      controller.correctCreation();
      expect(controller.hasCreationAttempt, isTrue);
      repository.create = (_, _) async =>
          throw const ApiException(ApiFailure.customerExists);
      await controller.createCustomer();
      expect(controller.canCorrectCreation, isTrue);
      controller.correctCreation();
      expect(controller.hasCreationAttempt, isFalse);
    },
  );

  test(
    'same-principal token refresh preserves pending retry but role change clears it',
    () async {
      final controller = await start(officer: true);
      repository.create = (_, _) async =>
          throw const ApiException(ApiFailure.unavailable);
      await controller.createCustomer(creationDraft);
      final generation = session.generation;
      auth.accessToken = 'refreshed-token';
      auth.events.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(session.generation, generation);
      expect(controller.hasCreationAttempt, isTrue);
      profiles.fetch = (_) async => demoProfile;
      await session.revalidateProfile();
      expect(session.profile?.role, AppRole.customer);
      expect(controller.hasCreationAttempt, isFalse);
    },
  );

  test(
    'transient resume revalidation preserves draft but 401 clears it',
    () async {
      final controller = await start(officer: true);
      repository.create = (_, _) async =>
          throw const ApiException(ApiFailure.unavailable);
      await controller.createCustomer(creationDraft);
      profiles.fetch = (_) async =>
          throw const ApiException(ApiFailure.unavailable);
      await session.revalidateProfile();
      expect(session.status, SessionStatus.ready);
      expect(controller.hasCreationAttempt, isTrue);
      profiles.fetch = (_) async =>
          throw const ApiException(ApiFailure.unauthorized);
      await session.revalidateProfile();
      expect(session.status, SessionStatus.signedOut);
      expect(controller.hasCreationAttempt, isFalse);
    },
  );

  test(
    'customer cannot call officer creation even if UI is bypassed',
    () async {
      final controller = await start();
      expect(await controller.createCustomer(creationDraft), isNull);
      expect(repository.createCalls, 0);
      expect(controller.creationError, contains('permission'));
    },
  );

  test(
    'contact failure retains profile; retry applies server response',
    () async {
      final controller = await start();
      repository.contact = (_, _) async =>
          throw const ApiException(ApiFailure.unavailable);
      expect(await controller.saveContact('+84 12345', 'Address'), isFalse);
      expect(session.profile?.phone, isNull);
      expect(controller.contactError, contains('connection'));
      repository.contact = (phone, address) async => UserProfile(
        id: demoProfile.id,
        email: demoProfile.email,
        displayName: demoProfile.displayName,
        role: demoProfile.role,
        phone: phone,
        address: address,
      );
      expect(await controller.saveContact('+84 12345', 'Address'), isTrue);
      expect(session.profile?.phone, '+84 12345');
      expect(controller.contactError, isNull);
    },
  );

  test(
    'contact result for another identity cannot replace own profile',
    () async {
      final controller = await start();
      repository.contact = (_, _) async => const UserProfile(
        id: 'other-user',
        email: 'other@example.test',
        displayName: 'Other user',
        role: AppRole.customer,
      );
      expect(await controller.saveContact(null, null), isFalse);
      expect(session.profile?.id, demoProfile.id);
    },
  );

  test('creation retries original UUID/body and blocks double submit', () async {
    final controller = await start(officer: true);
    final pending = Completer<CustomerDetail>();
    repository.create = (_, _) => pending.future;
    final first = controller.createCustomer(creationDraft);
    expect(await controller.createCustomer(creationDraft), isNull);
    expect(repository.createCalls, 1);
    pending.completeError(const ApiException(ApiFailure.unavailable));
    expect(await first, isNull);
    expect(controller.hasCreationAttempt, isTrue);
    expect(controller.canCorrectCreation, isFalse);
    expect(controller.creationError, contains('may already have been created'));
    repository.create = (_, _) async => demoCustomer;
    final result = await controller.createCustomer(
      const CustomerDraft(
        email: 'different@example.test',
        displayName: 'Different body',
        phone: null,
        address: null,
        initialPassword: 'different-password',
      ),
    );
    expect(result?.id, demoCustomer.id);
    expect(repository.creationKeys[1], repository.creationKeys[0]);
    expect(repository.creationDrafts[1], same(creationDraft));
    expect(
      repository.creationKeys[0],
      matches(
        RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ),
      ),
    );
    expect(controller.hasCreationAttempt, isFalse);
  });

  test(
    'only validation rejection permits a corrected creation attempt',
    () async {
      final controller = await start(officer: true);
      repository.create = (_, _) async =>
          throw const ApiException(ApiFailure.invalidInput);
      await controller.createCustomer(creationDraft);
      expect(controller.canCorrectCreation, isTrue);
      controller.correctCreation();
      expect(controller.hasCreationAttempt, isFalse);
      repository.create = (_, _) async => demoCustomer;
      await controller.createCustomer(creationDraft);
      expect(repository.creationKeys[1], isNot(repository.creationKeys[0]));
    },
  );

  test(
    'late creation cannot display data or keep password after sign-out',
    () async {
      final controller = await start(officer: true);
      final pending = Completer<CustomerDetail>();
      repository.create = (_, _) => pending.future;
      final request = controller.createCustomer(creationDraft);
      await session.signOut();
      expect(controller.hasCreationAttempt, isFalse);
      pending.complete(demoCustomer);
      expect(await request, isNull);
      expect(controller.selectedCustomer, isNull);
      expect(session.status, SessionStatus.signedOut);
    },
  );

  test('late accounts cannot cross session refresh or user change', () async {
    final controller = await start();
    final pending = Completer<List<BankAccount>>();
    repository.accounts = (_) => pending.future;
    final request = controller.loadAccounts();
    auth.userId = 'other-user';
    await session.loadProfile();
    pending.complete([demoAccount]);
    await request;
    expect(controller.accounts, isNull);
  });

  test('banking 401 locks session and discards protected state', () async {
    final controller = await start();
    repository.accounts = (_) async =>
        throw const ApiException(ApiFailure.unauthorized);
    await controller.loadAccounts();
    expect(session.status, SessionStatus.signedOut);
    expect(controller.accounts, isNull);
    expect(session.message, contains('expired'));
  });

  test(
    'new search supersedes old results and blank search clears them',
    () async {
      final controller = await start(officer: true);
      final old = Completer<List<CustomerSummary>>();
      repository.search = (query) =>
          query == 'old' ? old.future : Future.value([]);
      final request = controller.search('old');
      await controller.search('new');
      old.complete([demoCustomer]);
      await request;
      expect(controller.customers, isEmpty);
      await controller.search('');
      expect(controller.customers, isNull);
    },
  );

  test(
    'requested change preserves customer identity and uses returned data',
    () async {
      final controller = await start(officer: true);
      await controller.loadCustomer(demoCustomer.id);
      expect(
        await controller.saveCustomer(
          displayName: 'Corrected Name',
          phone: null,
          address: 'New address',
          requestReason: 'Customer requested correction',
        ),
        isTrue,
      );
      expect(controller.selectedCustomer?.id, demoCustomer.id);
      expect(controller.selectedCustomer?.displayName, 'Corrected Name');
      expect(controller.selectedCustomer?.phone, isNull);
    },
  );
}
