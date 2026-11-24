import 'dart:async';

import 'package:nene_app/data/auth_repository.dart';
import 'package:nene_app/data/banking_repository.dart';
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

const officerProfile = UserProfile(
  id: 'user-id',
  email: 'officer@example.test',
  displayName: 'Demo Officer',
  role: AppRole.officer,
);

const demoAccount = BankAccount(
  id: 'account-id',
  accountNumber: '100000000001',
  type: 'checking',
  currency: 'VND',
  balanceMinor: '0',
  status: 'active',
);

const demoCustomer = CustomerDetail(
  id: 'customer-id',
  email: 'new@example.test',
  displayName: 'New Customer',
  phone: '+84 12345',
  address: 'Demo address',
  accounts: [demoAccount],
);

class FakeBanking implements BankingRepository {
  Future<List<BankAccount>> Function(String) accounts = (_) async => [
    demoAccount,
  ];
  Future<UserProfile> Function(String?, String?) contact =
      (phone, address) async => UserProfile(
        id: demoProfile.id,
        email: demoProfile.email,
        displayName: demoProfile.displayName,
        role: demoProfile.role,
        phone: phone,
        address: address,
      );
  Future<CustomerDetail> Function(CustomerDraft, String) create =
      (_, _) async => demoCustomer;
  Future<List<CustomerSummary>> Function(String) search = (_) async => [
    demoCustomer,
  ];
  Future<CustomerDetail> Function(String) detail = (_) async => demoCustomer;
  Future<CustomerDetail> Function(String, String?, String?, String) update =
      (name, phone, address, reason) async => CustomerDetail(
        id: demoCustomer.id,
        email: demoCustomer.email,
        displayName: name,
        phone: phone,
        address: address,
        accounts: demoCustomer.accounts,
      );
  int createCalls = 0;
  int contactCalls = 0;
  int accountsCalls = 0;
  final creationKeys = <String>[];
  final creationDrafts = <CustomerDraft>[];

  @override
  Future<List<BankAccount>> getAccounts(String token) {
    accountsCalls++;
    return accounts(token);
  }

  @override
  Future<UserProfile> updateContact(
    String token, {
    required String? phone,
    required String? address,
  }) {
    contactCalls++;
    return contact(phone, address);
  }

  @override
  Future<CustomerDetail> createCustomer(
    String token,
    CustomerDraft draft,
    String idempotencyKey,
  ) {
    createCalls++;
    creationKeys.add(idempotencyKey);
    creationDrafts.add(draft);
    return create(draft, idempotencyKey);
  }

  @override
  Future<List<CustomerSummary>> findCustomers(String token, String query) =>
      search(query);

  @override
  Future<CustomerDetail> getCustomer(String token, String id) => detail(id);

  @override
  Future<CustomerDetail> updateCustomer(
    String token,
    String id, {
    required String displayName,
    required String? phone,
    required String? address,
    required String requestReason,
  }) => update(displayName, phone, address, requestReason);
}
