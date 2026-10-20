import 'dart:math';

import 'package:flutter/foundation.dart';

import 'data/banking_repository.dart';
import 'data/profile_api.dart';
import 'data/user_profile.dart';
import 'session_controller.dart';

/// Owns request state for one authenticated workspace. A session transition
/// clears sensitive state and makes every outstanding request result obsolete.
class CustomerFlowController extends ChangeNotifier {
  CustomerFlowController({
    required SessionController session,
    required BankingRepository repository,
  }) : _session = session,
       _repository = repository,
       _generation = session.generation {
    _session.addListener(_onSessionChanged);
  }

  final SessionController _session;
  final BankingRepository _repository;
  final int _generation;
  bool _disposed = false;
  bool _active = true;
  int _searchRevision = 0;
  int _detailRevision = 0;

  List<BankAccount>? accounts;
  bool loadingAccounts = false;
  String? accountsError;
  bool savingContact = false;
  String? contactError;

  List<CustomerSummary>? customers;
  String searchQuery = '';
  bool searching = false;
  String? searchError;
  CustomerDetail? selectedCustomer;
  bool loadingCustomer = false;
  String? customerError;
  bool savingCustomer = false;
  String? customerSaveError;

  CustomerDraft? _creationDraft;
  String? _creationKey;
  ApiFailure? _creationFailure;
  bool creating = false;
  String? creationError;

  bool get hasCreationAttempt => _creationDraft != null;
  bool get canCorrectCreation =>
      _creationFailure == ApiFailure.invalidInput ||
      _creationFailure == ApiFailure.customerExists;
  bool get _current =>
      !_disposed &&
      _active &&
      _session.status == SessionStatus.ready &&
      _generation == _session.generation;

  Future<void> loadAccounts() async {
    if (!_current || loadingAccounts) return;
    loadingAccounts = true;
    accountsError = null;
    _notify();
    try {
      final loaded = await _session.authorized(
        _repository.getAccounts,
        role: AppRole.customer,
      );
      if (_current) accounts = loaded;
    } catch (error) {
      if (_current) accountsError = failureMessage(error, 'load your accounts');
    } finally {
      if (_current) {
        loadingAccounts = false;
        _notify();
      }
    }
  }

  Future<bool> saveContact(String? phone, String? address) async {
    if (!_current || savingContact) return false;
    savingContact = true;
    contactError = null;
    _notify();
    try {
      final updated = await _session.authorized(
        (token) =>
            _repository.updateContact(token, phone: phone, address: address),
        role: AppRole.customer,
      );
      if (!_current) return false;
      _session.acceptOwnProfile(updated);
      return true;
    } catch (error) {
      if (_current) {
        contactError = failureMessage(error, 'save your contact details');
      }
      return false;
    } finally {
      if (_current) {
        savingContact = false;
        _notify();
      }
    }
  }

  Future<void> search(String query) async {
    if (!_current) return;
    final revision = ++_searchRevision;
    searchQuery = query.trim();
    customers = null;
    searchError = null;
    if (query.trim().isEmpty) {
      searching = false;
      _notify();
      return;
    }
    searching = true;
    _notify();
    try {
      final result = await _session.authorized(
        (token) => _repository.findCustomers(token, query.trim()),
        role: AppRole.officer,
      );
      if (_current && revision == _searchRevision) customers = result;
    } catch (error) {
      if (_current && revision == _searchRevision) {
        searchError = failureMessage(error, 'find customers');
      }
    } finally {
      if (_current && revision == _searchRevision) {
        searching = false;
        _notify();
      }
    }
  }

  Future<void> loadCustomer(String id) async {
    if (!_current) return;
    final revision = ++_detailRevision;
    selectedCustomer = null;
    customerError = null;
    customerSaveError = null;
    loadingCustomer = true;
    _notify();
    try {
      final result = await _session.authorized(
        (token) => _repository.getCustomer(token, id),
        role: AppRole.officer,
      );
      if (result.id != id) {
        throw const ApiException(ApiFailure.invalidResponse);
      }
      if (_current && revision == _detailRevision) selectedCustomer = result;
    } catch (error) {
      if (_current && revision == _detailRevision) {
        customerError = failureMessage(error, 'load this customer');
      }
    } finally {
      if (_current && revision == _detailRevision) {
        loadingCustomer = false;
        _notify();
      }
    }
  }

  Future<bool> saveCustomer({
    required String displayName,
    required String? phone,
    required String? address,
    required String requestReason,
  }) async {
    final id = selectedCustomer?.id;
    if (!_current || savingCustomer || id == null) return false;
    savingCustomer = true;
    customerSaveError = null;
    _notify();
    try {
      final updated = await _session.authorized(
        (token) => _repository.updateCustomer(
          token,
          id,
          displayName: displayName,
          phone: phone,
          address: address,
          requestReason: requestReason,
        ),
        role: AppRole.officer,
      );
      if (updated.id != id) {
        throw const ApiException(ApiFailure.invalidResponse);
      }
      if (!_current || selectedCustomer?.id != id) return false;
      selectedCustomer = updated;
      // Search summaries are now stale; the next search fetches fresh results.
      customers = null;
      return true;
    } catch (error) {
      if (_current) {
        customerSaveError = failureMessage(error, 'save this customer');
      }
      return false;
    } finally {
      if (_current) {
        savingCustomer = false;
        _notify();
      }
    }
  }

  /// Passing a draft starts an attempt only when none exists. Every retry uses
  /// the original immutable body and UUID, including after a lost response.
  Future<CustomerDetail?> createCustomer([CustomerDraft? draft]) async {
    if (!_current || creating) return null;
    if (_creationDraft == null) {
      if (draft == null) return null;
      _creationDraft = draft;
      _creationKey = _uuid();
    }
    creating = true;
    creationError = null;
    _creationFailure = null;
    _notify();
    try {
      final result = await _session.authorized(
        (token) =>
            _repository.createCustomer(token, _creationDraft!, _creationKey!),
        role: AppRole.officer,
      );
      if (!_current) return null;
      selectedCustomer = result;
      customers = null;
      _clearCreation();
      return result;
    } catch (error) {
      if (_current) {
        _creationFailure = error is ApiException ? error.failure : null;
        creationError = switch (_creationFailure) {
          ApiFailure.invalidInput =>
            'Some details were not accepted. Go back to correct them.',
          ApiFailure.customerExists =>
            'A customer with this email already exists. Edit the email or return '
                'to find the existing customer. This request did not create another customer.',
          ApiFailure.conflict =>
            'The email or request conflicts with an existing record. Retry this same request to check its outcome. Do not create a second request for this email.',
          ApiFailure.forbidden =>
            'You do not have permission to create customers.',
          _ =>
            'Creation could not be confirmed. Keep this screen open and retry the same request. The customer may already have been created.',
        };
      }
      return null;
    } finally {
      if (_current) {
        creating = false;
        _notify();
      }
    }
  }

  /// Only validation rejection or a confirmed preexisting email permits a fresh
  /// corrected body/key. Uncertain outcomes remain tied to their first request.
  void correctCreation() {
    if (!_current || creating || !canCorrectCreation) return;
    _clearCreation();
    _notify();
  }

  void clearContactError() {
    contactError = null;
  }

  void clearCustomerSaveError() {
    customerSaveError = null;
  }

  void _clearCreation() {
    _creationDraft = null;
    _creationKey = null;
    _creationFailure = null;
    creationError = null;
    creating = false;
  }

  void _onSessionChanged() {
    if (_current) return;
    _active = false;
    accounts = null;
    customers = null;
    selectedCustomer = null;
    searchQuery = '';
    _clearCreation();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _clearCreation();
    accounts = null;
    customers = null;
    selectedCustomer = null;
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }
}

String failureMessage(Object error, String action) => switch (error) {
  ApiException(failure: ApiFailure.forbidden) =>
    'You do not have permission to $action.',
  ApiException(failure: ApiFailure.invalidInput) =>
    'Some details were not accepted. Check the fields and try again.',
  ApiException(failure: ApiFailure.notFound) =>
    'This record is no longer available. Return and search again.',
  ApiException(failure: ApiFailure.conflict) =>
    'These details conflict with an existing record. Check them and try again.',
  _ => 'Unable to $action. Check your connection and try again.',
};

String _uuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
