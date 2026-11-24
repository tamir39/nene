import 'dart:typed_data';

class IdentitySummary {
  const IdentitySummary({
    required this.customerId,
    required this.customerName,
    required this.status,
    required this.allowedActions,
    required this.noticeVersion,
    required this.noticeText,
    this.caseId,
    this.version,
    this.revision,
    this.evidenceId,
    this.correctionReason,
    this.expiresAt,
    this.expired = false,
  });

  factory IdentitySummary.fromJson(Map<String, dynamic> json) {
    const statuses = {
      'not_started',
      'draft',
      'submitted',
      'needs_changes',
      'reference_accepted',
    };
    final notice = json['notice'];
    final actions = json['allowedActions'];
    if (json['customerId'] is! String ||
        json['customerName'] is! String ||
        !statuses.contains(json['status']) ||
        notice is! Map<String, dynamic> ||
        notice['version'] is! String ||
        notice['text'] is! String ||
        actions is! List ||
        actions.any((a) => a is! String) ||
        json['expired'] is! bool ||
        (json['caseId'] != null && json['caseId'] is! String) ||
        (json['version'] != null && json['version'] is! int) ||
        (json['revision'] != null && json['revision'] is! int) ||
        (json['evidenceId'] != null && json['evidenceId'] is! String) ||
        (json['correctionReason'] != null &&
            json['correctionReason'] is! String) ||
        (json['expiresAt'] != null && json['expiresAt'] is! String) ||
        (json['status'] != 'not_started' &&
            (json['caseId'] == null || json['version'] == null))) {
      throw const FormatException('Invalid identity reference.');
    }
    return IdentitySummary(
      customerId: json['customerId'] as String,
      customerName: json['customerName'] as String,
      status: json['status'] as String,
      caseId: json['caseId'] as String?,
      version: json['version'] as int?,
      revision: json['revision'] as int?,
      evidenceId: json['evidenceId'] as String?,
      correctionReason: json['correctionReason'] as String?,
      expiresAt: json['expiresAt'] == null
          ? null
          : DateTime.parse(json['expiresAt'] as String),
      expired: json['expired'] as bool,
      noticeVersion: notice['version'] as String,
      noticeText: notice['text'] as String,
      allowedActions: Set.unmodifiable(actions.cast<String>()),
    );
  }

  final String customerId;
  final String customerName;
  final String status;
  final String? caseId;
  final int? version;
  final int? revision;
  final String? evidenceId;
  final String? correctionReason;
  final DateTime? expiresAt;
  final bool expired;
  final String noticeVersion;
  final String noticeText;
  final Set<String> allowedActions;

  String get label => switch (status) {
    'draft' => 'Draft',
    'submitted' => 'Awaiting officer review',
    'needs_changes' => expired ? 'Reference expired' : 'Changes requested',
    'reference_accepted' => 'Reference accepted',
    _ => 'Not started',
  };
}

abstract interface class IdentityRepository {
  Future<IdentitySummary> getSummary(String token, {String? customerId});
  Future<IdentitySummary> start(
    String token, {
    String? customerId,
    required String noticeVersion,
    required String key,
  });
  Future<IdentitySummary> upload(
    String token,
    String caseId, {
    required int version,
    required String contentType,
    required Uint8List bytes,
    required String key,
  });
  Future<IdentitySummary> submit(
    String token,
    String caseId, {
    required int version,
    required String key,
  });
  Future<IdentitySummary> review(
    String token,
    String caseId, {
    required int version,
    required String action,
    required bool associationConfirmed,
    String? reason,
    required String key,
  });
  Future<Uint8List> getEvidence(String token, String caseId, String evidenceId);
}
