import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'security_api.dart';
import 'session_owner.dart';

enum CashOperation { deposit, withdrawal }

class ConfirmationApi {
  ConfirmationApi(
    this.security, {
    bool sendMoney = false,
    this.cashOperation,
    this.interbank = false,
  }) : sendMoney = sendMoney || cashOperation != null || interbank {
    if (interbank && cashOperation != null) {
      throw ArgumentError('A cash operation cannot be an interbank transfer.');
    }
  }
  final CashOperation? cashOperation;
  final bool interbank;
  String get route => cashOperation != null
      ? 'cash/${cashOperation!.name}'
      : interbank
      ? 'interbank-transfers'
      : sendMoney
      ? 'transfers'
      : 'transfer-confirmations';
  final SecurityApi security;
  final bool sendMoney;
  Future<Map<String, dynamic>> _request(
    String token,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final req =
        http.Request(
            body == null ? 'GET' : 'POST',
            security.baseUrl.resolve('me/$route/$path'),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          });
    if (body != null) req.body = jsonEncode(body);
    final response = await security.client
        .send(req)
        .then((response) async {
          final bytes = <int>[];
          await for (final chunk in response.stream) {
            if (bytes.length + chunk.length > 65536) {
              throw const SessionCoordinationException();
            }
            bytes.addAll(chunk);
          }
          return http.Response.bytes(bytes, response.statusCode);
        })
        .timeout(const Duration(seconds: 15));
    if ([400, 429].contains(response.statusCode)) {
      throw const SessionMutationRejected();
    }
    if (response.statusCode == 409 &&
        path == 'confirm' &&
        _code(response.body) == 'FACE_CHECK_REQUIRED') {
      throw const FaceCheckRequired();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const SessionCoordinationException();
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (interbank) _validateInterbank(data, path);
    return data;
  }

  void _validateInterbank(Map<String, dynamic> data, String path) {
    void require(bool condition) {
      if (!condition) throw const SessionCoordinationException();
    }

    if (path.isEmpty) {
      require(data['transfers'] is List);
      for (final entry in data['transfers'] as List) {
        _validateInterbank(entry as Map<String, dynamic>, 'status');
      }
      return;
    }
    require(data['simulated'] == true);
    if (path == 'configuration') {
      require(data['enabled'] is bool && data['currency'] == 'VND');
      // The amount rules live on the backend; the app only needs a well-formed value.
      require(
        data['highValueThresholdMinor'] is String &&
            RegExp(
              r'^[1-9]\d{0,15}$',
            ).hasMatch(data['highValueThresholdMinor'] as String),
      );
      require(data['banks'] is List && (data['banks'] as List).length <= 20);
      final codes = <String>{};
      for (final bank in data['banks'] as List) {
        require(bank is Map<String, dynamic>);
        require(bank['code'] is String && bank['name'] is String);
        require(codes.add(bank['code'] as String));
        require(bank['recipients'] is List);
        final accounts = <String>{};
        for (final recipient in bank['recipients'] as List) {
          require(recipient is Map<String, dynamic>);
          require(
            recipient['accountNumber'] is String && recipient['name'] is String,
          );
          require(
            RegExp(r'^\d{12}$').hasMatch(recipient['accountNumber'] as String),
          );
          require(accounts.add(recipient['accountNumber'] as String));
        }
      }
    }
    final receipt = data['receipt'];
    require(data['state'] != 'posted' || receipt is Map<String, dynamic>);
    if (receipt != null) {
      require(receipt is Map<String, dynamic> && receipt['simulated'] == true);
      require(receipt['currency'] == 'VND');
      for (final key in [
        'destinationBankCode',
        'destinationBankName',
        'destinationAccountNumber',
        'destinationRecipientName',
        'amountMinor',
      ]) {
        require(receipt[key] is String && (receipt[key] as String).isNotEmpty);
      }
    }
  }

  Future<Map<String, dynamic>> review(
    String source,
    String destination,
    String amount, {
    String? destinationBankCode,
  }) => security.owner.execute((s) async {
    final data = await _request(s.pair.accessToken, 'review', {
      if (cashOperation != null)
        'accountId': source
      else ...{
        'sourceAccountId': source,
        'destinationAccountNumber': destination,
        if (interbank) 'destinationBankCode': destinationBankCode,
      },
      'amountMinor': amount,
    });
    if (interbank &&
        (data['destinationBankCode'] != destinationBankCode ||
            data['destinationAccountNumber'] != destination ||
            data['amountMinor'] != amount ||
            data['currency'] != 'VND' ||
            data['destinationBankName'] is! String ||
            data['destinationRecipientName'] is! String)) {
      throw const SessionCoordinationException();
    }
    return data;
  });
  Future<Map<String, dynamic>> status(String id) =>
      security.owner.execute((s) => _request(s.pair.accessToken, id));
  Future<Map<String, dynamic>> configuration() => security.owner.execute(
    (s) => _request(s.pair.accessToken, 'configuration'),
  );
  Future<Map<String, dynamic>> recent() =>
      security.owner.execute((s) => _request(s.pair.accessToken, ''));
  Future<Map<String, dynamic>> cancel(String token) => security.owner.execute(
    (s) => _request(s.pair.accessToken, 'cancel', {'reviewToken': token}),
  );

  /// Sends [faceCheckId] when the review needed a face check. Throws
  /// [FaceCheckRequired] when the server asks for a (new) face check first.
  Future<Map<String, dynamic>> confirm(
    Map<String, dynamic> review,
    String code, {
    String? faceCheckId,
  }) async {
    Map<String, dynamic>? response;
    var faceRequired = false;
    try {
      await security.owner.exchange(
        HandoffBinding(
          requestId: review['requestId'] as String,
          purpose: cashOperation != null
              ? 'cash-${cashOperation!.name}'
              : interbank
              ? 'interbank-transfer'
              : sendMoney
              ? 'same-bank-transfer'
              : 'transaction-confirmation',
          securityRevision: review['revision'] as int,
        ),
        (s) async {
          final Map<String, dynamic> data;
          try {
            data = await _request(s.pair.accessToken, 'confirm', {
              'reviewToken': review['reviewToken'],
              'code': code,
              'faceCheckId': ?faceCheckId,
            });
          } on FaceCheckRequired {
            faceRequired = true;
            rethrow;
          }
          response = data;
          if (interbank && data['requestId'] != review['requestId']) {
            throw const SessionCoordinationException();
          }
          if (interbank && data['receipt'] != null) {
            final receipt = data['receipt'] as Map<String, dynamic>;
            for (final key in [
              'destinationBankCode',
              'destinationAccountNumber',
              'amountMinor',
            ]) {
              if (receipt[key] != review[key]) {
                throw const SessionCoordinationException();
              }
            }
          }
          // A duplicate returns status only, never replays a provider session pair.
          if (data['replay'] == true) throw const SessionMutationRejected();
          if (data['sent'] != sendMoney ||
              data['executionAvailable'] != sendMoney ||
              data['state'] != (sendMoney ? 'posted' : 'factor_confirmed')) {
            throw const SessionCoordinationException();
          }
          return HandoffReply(
            pair: AuthPair(
              accessToken: data['accessToken'] as String,
              refreshToken: data['refreshToken'] as String,
            ),
            binding: HandoffBinding(
              requestId: data['requestId'] as String,
              purpose: data['purpose'] as String,
              securityRevision: data['revision'] as int,
            ),
          );
        },
      );
    } on SessionMutationRejected {
      // The session owner reports every authoritative rejection the same way.
      if (faceRequired) throw const FaceCheckRequired();
      if (response?['replay'] != true) rethrow;
    }
    return response!;
  }

  /// Compares one selfie with the customer's accepted reference photo on the
  /// server, for the review behind [reviewToken].
  ///
  /// The request uses the current access token without the session lease,
  /// like other non-rotating uploads, so a slow comparison cannot time out
  /// the lease and sign the customer out. A result that arrives after the
  /// session changed is discarded.
  Future<FaceCheckOutcome> faceCheck({
    required String reviewToken,
    required Uint8List selfie,
    required String contentType,
    required bool blink,
    required bool turn,
    required String idempotencyKey,
  }) async {
    final owner = security.owner;
    final session = owner.session;
    final generation = owner.generation;
    if (session == null) throw const SessionCoordinationException();
    final type = contentType.split('/');
    final request =
        http.MultipartRequest(
            'POST',
            security.baseUrl.resolve('me/face-checks'),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer ${session.pair.accessToken}',
            'Accept': 'application/json',
            'Idempotency-Key': idempotencyKey,
          })
          ..fields['reviewToken'] = reviewToken
          ..fields['liveness'] = jsonEncode({'blink': blink, 'turn': turn})
          ..files.add(
            http.MultipartFile.fromBytes(
              'selfie',
              selfie,
              filename: type.last == 'png' ? 'selfie.png' : 'selfie.jpg',
              contentType: MediaType(type.first, type.last),
            ),
          );
    int status;
    String body;
    try {
      final response = await security.client
          .send(request)
          .then((response) async {
            final bytes = <int>[];
            await for (final chunk in response.stream) {
              if (bytes.length + chunk.length > 65536) {
                throw const FormatException();
              }
              bytes.addAll(chunk);
            }
            return http.Response.bytes(bytes, response.statusCode);
          })
          .timeout(const Duration(seconds: 60));
      status = response.statusCode;
      body = utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (_) {
      _stillCurrent(owner, generation, session);
      return const FaceCheckOutcome.unavailable();
    }
    _stillCurrent(owner, generation, session);
    Object? data;
    try {
      data = jsonDecode(body);
    } on FormatException {
      data = null;
    }
    final json = data is Map<String, dynamic>
        ? data
        : const <String, Object?>{};
    switch (status) {
      case 200 || 201:
        final id = json['faceCheckId'];
        final expires = json['expiresAt'] is String
            ? DateTime.tryParse(json['expiresAt'] as String)
            : null;
        if (json['matched'] != true ||
            id is! String ||
            !_uuidPattern.hasMatch(id) ||
            expires == null) {
          return const FaceCheckOutcome.unavailable();
        }
        return FaceCheckOutcome.matched(id, expires);
      case 422:
        return FaceCheckOutcome.refused(switch (json['reason']) {
          'no_face' => FaceCheckRefusal.noFace,
          'multiple_faces' => FaceCheckRefusal.multipleFaces,
          _ => FaceCheckRefusal.notMatched,
        });
      case 400 || 413:
        return const FaceCheckOutcome.refused(FaceCheckRefusal.invalidPhoto);
      case 429:
        return const FaceCheckOutcome.stopped(FaceCheckStop.tooManyAttempts);
      case 401 || 403:
        return const FaceCheckOutcome.stopped(FaceCheckStop.signIn);
      case 409:
        return const FaceCheckOutcome.stopped(FaceCheckStop.notAvailable);
      default:
        return const FaceCheckOutcome.unavailable();
    }
  }

  void _stillCurrent(SessionOwner owner, int generation, OwnedSession origin) {
    if (owner.generation != generation ||
        owner.session?.userId != origin.userId) {
      throw const SessionCoordinationException();
    }
  }
}

String? _code(String body) {
  try {
    final data = jsonDecode(body);
    return data is Map<String, dynamic> && data['code'] is String
        ? data['code'] as String
        : null;
  } on FormatException {
    return null;
  }
}

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// The server needs a matched, unexpired face check before this transfer.
class FaceCheckRequired extends SessionMutationRejected {
  const FaceCheckRequired();
}

/// Why the server did not match a selfie. The customer may try again.
enum FaceCheckRefusal { noFace, multipleFaces, notMatched, invalidPhoto }

/// Why no further face check is possible for this review.
enum FaceCheckStop { tooManyAttempts, signIn, notAvailable }

/// Result of `POST /me/face-checks`. Exactly one of [faceCheckId],
/// [refusal] or [stop] is set, unless the outcome is unknown (network or
/// server failure), when none is.
class FaceCheckOutcome {
  const FaceCheckOutcome.matched(
    String this.faceCheckId,
    DateTime this.expiresAt,
  ) : refusal = null,
      stop = null;
  const FaceCheckOutcome.refused(FaceCheckRefusal this.refusal)
    : faceCheckId = null,
      expiresAt = null,
      stop = null;
  const FaceCheckOutcome.stopped(FaceCheckStop this.stop)
    : faceCheckId = null,
      expiresAt = null,
      refusal = null;
  const FaceCheckOutcome.unavailable()
    : faceCheckId = null,
      expiresAt = null,
      refusal = null,
      stop = null;
  final String? faceCheckId;
  final DateTime? expiresAt;
  final FaceCheckRefusal? refusal;
  final FaceCheckStop? stop;
}

/// A fresh random UUID v4 for an `Idempotency-Key` header.
String newIdempotencyKey() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
