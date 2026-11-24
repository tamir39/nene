import 'dart:io';
import 'dart:typed_data';

import 'package:nene_app/data/identity_repository.dart';
import 'package:nene_app/data/reference_photo_source.dart';

Uint8List get referenceFixture =>
    File('test/fixtures/reference-test.png').readAsBytesSync();

Map<String, dynamic> identityJson({
  String status = 'not_started',
  int version = 1,
  String customerId = 'user-id',
  bool expired = false,
}) => {
  'customerId': customerId,
  'customerName': 'Demo Student',
  'status': status,
  'caseId': status == 'not_started' ? null : 'case-id',
  'version': status == 'not_started' ? null : version,
  'revision': status == 'not_started' ? null : 1,
  'evidenceId':
      expired || status == 'not_started' || (status == 'draft' && version == 1)
      ? null
      : 'evidence-id',
  'correctionReason': status == 'needs_changes'
      ? 'Please provide a clearer photo.'
      : null,
  'expiresAt': status == 'not_started' ? null : '2026-11-03T12:00:00Z',
  'expired': expired,
  'notice': {
    'version': 'reference-demo-v1',
    'text':
        'This coursework demo stores one private reference photo for officer review. Acceptance is not completed eKYC or proof of live presence. Access expires after 7 days; expired and abandoned files are removed when local maintenance runs. Use only agreed test images.',
  },
  'allowedActions':
      expired || status == 'not_started' || status == 'needs_changes'
      ? ['start']
      : status == 'draft'
      ? ['capture', if (version > 1) 'submit']
      : status == 'submitted'
      ? ['accept_reference', 'request_changes']
      : <String>[],
};

class FakeIdentity implements IdentityRepository {
  IdentitySummary value = IdentitySummary.fromJson(identityJson());
  Future<IdentitySummary> Function()? fetch;
  Future<IdentitySummary> Function(String key)? startAction;
  Future<IdentitySummary> Function(String key)? uploadAction;
  Future<IdentitySummary> Function(String key)? reviewAction;
  Future<Uint8List> Function()? preview;
  final startKeys = <String>[];
  final uploadKeys = <String>[];
  final reviewActions = <String>[];
  bool? acknowledgedAssociation;
  int submits = 0;

  IdentitySummary set(String status, int version, {bool expired = false}) =>
      value = IdentitySummary.fromJson(
        identityJson(
          status: status,
          version: version,
          customerId: value.customerId,
          expired: expired,
        ),
      );
  @override
  Future<IdentitySummary> getSummary(
    String token, {
    String? customerId,
  }) async => fetch == null ? value : fetch!();
  @override
  Future<IdentitySummary> start(
    String token, {
    String? customerId,
    required String noticeVersion,
    required String key,
  }) async {
    startKeys.add(key);
    if (startAction != null) return startAction!(key);
    return set('draft', (value.version ?? 0) + 1);
  }

  @override
  Future<IdentitySummary> upload(
    String token,
    String caseId, {
    required int version,
    required String contentType,
    required Uint8List bytes,
    required String key,
  }) async {
    uploadKeys.add(key);
    if (uploadAction != null) return uploadAction!(key);
    return set('draft', version + 1);
  }

  @override
  Future<IdentitySummary> submit(
    String token,
    String caseId, {
    required int version,
    required String key,
  }) async {
    submits++;
    return set('submitted', version + 1);
  }

  @override
  Future<IdentitySummary> review(
    String token,
    String caseId, {
    required int version,
    required String action,
    required bool associationConfirmed,
    String? reason,
    required String key,
  }) async {
    reviewActions.add(action);
    acknowledgedAssociation = associationConfirmed;
    if (reviewAction != null) return reviewAction!(key);
    return set(
      action == 'accept_reference' ? 'reference_accepted' : 'needs_changes',
      version + 1,
    );
  }

  @override
  Future<Uint8List> getEvidence(
    String token,
    String caseId,
    String evidenceId,
  ) async => preview == null ? referenceFixture : preview!();
}

class FakePhotos implements ReferencePhotoSource {
  Future<ReferencePhoto?> Function() pick = () async =>
      ReferencePhoto(referenceFixture, 'image/png');
  @override
  Future<ReferencePhoto?> capture() => pick();
}
