import 'dart:math';

import 'package:flutter/foundation.dart';

import 'data/identity_repository.dart';
import 'data/profile_api.dart';
import 'data/reference_photo_source.dart';
import 'data/user_profile.dart';
import 'session_controller.dart';

class IdentityController extends ChangeNotifier {
  IdentityController({
    required SessionController session,
    required IdentityRepository repository,
    required ReferencePhotoSource photos,
    this.customerId,
  }) : _session = session,
       _repository = repository,
       _photos = photos,
       _generation = session.generation,
       _ownName = session.profile?.displayName {
    _session.addListener(_sessionChanged);
  }

  final SessionController _session;
  final IdentityRepository _repository;
  final ReferencePhotoSource _photos;
  final int _generation;
  String? _ownName;
  final String? customerId;
  bool _disposed = false;
  bool _active = true;
  int _request = 0;
  IdentitySummary? summary;
  ReferencePhoto? captured;
  Uint8List? evidence;
  String? message;
  String? error;
  bool busy = false;
  bool capturing = false;
  bool mustCheckStatus = false;
  _Pending? _pending;

  bool get officer => customerId != null;
  bool get _current =>
      !_disposed &&
      _active &&
      _session.status == SessionStatus.ready &&
      _generation == _session.generation;
  bool get canRetry => _pending != null && !mustCheckStatus && !busy;
  bool get blocked => busy || capturing || mustCheckStatus || _pending != null;
  AppRole get _role => officer ? AppRole.officer : AppRole.customer;

  Future<T> _authorized<T>(Future<T> Function(String) action) =>
      _session.authorized(action, role: _role);

  Future<void> load() async {
    if (!_current || busy || capturing) return;
    final request = ++_request;
    busy = true;
    error = null;
    message = null;
    evidence = null;
    _notify();
    try {
      final value = await _authorized(
        (token) => _repository.getSummary(token, customerId: customerId),
      );
      if (!_current || request != _request) return;
      final previous = summary;
      _accept(value);
      if (previous != null &&
          (previous.version != value.version ||
              previous.customerName != value.customerName)) {
        captured = null;
      }
      final pending = _pending;
      if (pending != null &&
          (pending.caseId != value.caseId ||
              pending.version != value.version ||
              value.expired)) {
        _pending = null;
        captured = null;
        message =
            'Current reference status loaded. Review it before continuing.';
      }
      mustCheckStatus = false;
      await _loadEvidence(value, request);
    } catch (failure) {
      if (_current && request == _request) {
        mustCheckStatus = true;
        error = _messageFor(failure, writing: false);
      }
    } finally {
      if (_current && request == _request) {
        busy = false;
        _notify();
      }
    }
  }

  void _accept(IdentitySummary value) {
    final expectedId = customerId ?? _session.profile?.id;
    if (value.customerId != expectedId) {
      throw const ApiException(ApiFailure.invalidResponse);
    }
    summary = value;
  }

  Future<void> _loadEvidence(IdentitySummary value, int request) async {
    if (value.evidenceId == null || value.caseId == null || value.expired) {
      return;
    }
    try {
      final bytes = await _authorized(
        (token) =>
            _repository.getEvidence(token, value.caseId!, value.evidenceId!),
      );
      photoContentType(bytes);
      await validatePhotoDimensions(bytes);
      if (_current && request == _request) evidence = bytes;
    } catch (_) {
      if (_current && request == _request) {
        error =
            'The private photo could not be loaded. Check status to try again before reviewing it.';
      }
    }
  }

  Future<void> capture() async {
    if (!_current ||
        blocked ||
        !(summary?.allowedActions.contains('capture') ?? false)) {
      return;
    }
    final request = ++_request;
    capturing = true;
    error = null;
    message = null;
    _notify();
    try {
      final photo = await _photos.capture();
      if (_current && request == _request && photo != null) captured = photo;
    } on PhotoCaptureException catch (failure) {
      if (_current && request == _request) error = failure.message;
    } catch (_) {
      if (_current && request == _request) {
        error =
            'The camera is unavailable. Try again or ask your officer for assistance.';
      }
    } finally {
      if (_current && request == _request) {
        capturing = false;
        _notify();
      }
    }
  }

  Future<void> start({required bool acknowledged}) async {
    final value = summary;
    if (value == null ||
        !acknowledged ||
        !value.allowedActions.contains('start')) {
      return;
    }
    await _write(
      (token, key) => _repository.start(
        token,
        customerId: customerId,
        noticeVersion: value.noticeVersion,
        key: key,
      ),
    );
  }

  Future<void> upload() async {
    final value = summary;
    final photo = captured;
    if (value?.caseId == null ||
        value?.version == null ||
        photo == null ||
        !value!.allowedActions.contains('capture')) {
      return;
    }
    await _write(
      (token, key) => _repository.upload(
        token,
        value.caseId!,
        version: value.version!,
        contentType: photo.contentType,
        bytes: photo.bytes,
        key: key,
      ),
    );
  }

  Future<void> submit() async {
    final value = summary;
    if (value?.caseId == null ||
        value?.version == null ||
        captured != null ||
        !value!.allowedActions.contains('submit')) {
      return;
    }
    await _write(
      (token, key) => _repository.submit(
        token,
        value.caseId!,
        version: value.version!,
        key: key,
      ),
    );
  }

  Future<void> review({
    required bool accept,
    required bool associationConfirmed,
    String? reason,
  }) async {
    final value = summary;
    final action = accept ? 'accept_reference' : 'request_changes';
    if (!officer ||
        value?.caseId == null ||
        value?.version == null ||
        !value!.allowedActions.contains(action)) {
      return;
    }
    if (accept && (!associationConfirmed || evidence == null)) return;
    if (!accept &&
        (reason == null ||
            reason.trim().length < 5 ||
            reason.trim().length > 500)) {
      return;
    }
    await _write(
      (token, key) => _repository.review(
        token,
        value.caseId!,
        version: value.version!,
        action: action,
        associationConfirmed: accept && associationConfirmed,
        reason: accept ? null : reason!.trim(),
        key: key,
      ),
    );
  }

  Future<void> _write(
    Future<IdentitySummary> Function(String, String) action,
  ) async {
    if (!_current || blocked) return;
    _pending = _Pending(action, _uuid(), summary?.caseId, summary?.version);
    await _sendPending();
  }

  Future<void> retry() async {
    if (!_current || !canRetry) return;
    await _sendPending();
  }

  Future<void> _sendPending() async {
    final pending = _pending;
    if (pending == null) return;
    final request = ++_request;
    busy = true;
    message = null;
    error = null;
    _notify();
    try {
      final value = await _authorized(
        (token) => pending.action(token, pending.key),
      );
      if (!_current || request != _request) return;
      _accept(value);
      captured = null;
      evidence = null;
      _pending = null;
      mustCheckStatus = false;
      // Exact retries may return a newer authoritative state. Never narrate
      // the old intended outcome as if it were still the current decision.
      message = switch (value.status) {
        'draft' =>
          value.evidenceId == null
              ? 'Reference draft started. Take and review one photo.'
              : 'Photo saved privately. Review it, then submit the reference.',
        'submitted' => 'Reference submitted. Awaiting officer review.',
        'reference_accepted' => 'Reference accepted for later identity checks.',
        'needs_changes' =>
          value.expired
              ? 'Reference expired. Start a new reference to continue.'
              : 'Correction requested. Review the reason before providing a new photo.',
        _ => 'Current reference status loaded. Review it before continuing.',
      };
      await _loadEvidence(value, request);
    } catch (failure) {
      if (!_current || request != _request) return;
      error = _messageFor(failure, writing: true);
      if (failure is ApiException &&
          failure.failure == ApiFailure.invalidInput) {
        _pending = null;
      } else {
        mustCheckStatus = true;
        if (failure is ApiException &&
            {
              ApiFailure.conflict,
              ApiFailure.forbidden,
              ApiFailure.notFound,
            }.contains(failure.failure)) {
          _pending = null;
        }
      }
    } finally {
      if (_current && request == _request) {
        busy = false;
        _notify();
      }
    }
  }

  String _messageFor(
    Object failure, {
    required bool writing,
  }) => switch (failure) {
    ApiException(failure: ApiFailure.invalidInput) =>
      'The photo or details were not accepted. Use a valid JPEG/PNG up to 10 MiB and check the form.',
    ApiException(failure: ApiFailure.conflict) =>
      'This reference changed. Check status and review the latest version before continuing.',
    ApiException(failure: ApiFailure.forbidden) =>
      'You do not have permission for this reference action.',
    ApiException(failure: ApiFailure.notFound) =>
      'This reference is unavailable. Check status or return to the customer.',
    _ =>
      writing
          ? 'Outcome not confirmed. Check status before trying the same action again.'
          : 'Reference status is unavailable. Check your connection and try again.',
  };

  void _sessionChanged() {
    if (!_current) {
      _active = false;
      _clear();
      _notify();
    } else if (!officer && _ownName != _session.profile?.displayName) {
      _ownName = _session.profile?.displayName;
      _clear();
      mustCheckStatus = true;
      error = 'Your name changed. Check reference status before continuing.';
      _notify();
    }
  }

  void _clear() {
    _request++;
    captured = null;
    evidence = null;
    summary = null;
    _pending = null;
    busy = false;
    capturing = false;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _clear();
    _session.removeListener(_sessionChanged);
    super.dispose();
  }
}

class _Pending {
  const _Pending(this.action, this.key, this.caseId, this.version);
  final Future<IdentitySummary> Function(String, String) action;
  final String key;
  final String? caseId;
  final int? version;
}

String _uuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
