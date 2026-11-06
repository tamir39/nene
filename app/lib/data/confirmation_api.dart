import 'dart:convert';
import 'package:http/http.dart' as http;
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
      require(data['highValueThresholdMinor'] == '5000000');
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
  Future<Map<String, dynamic>> confirm(
    Map<String, dynamic> review,
    String code,
  ) async {
    Map<String, dynamic>? response;
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
          final data = await _request(s.pair.accessToken, 'confirm', {
            'reviewToken': review['reviewToken'],
            'code': code,
          });
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
      if (response?['replay'] != true) rethrow;
    }
    return response!;
  }
}
