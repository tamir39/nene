import 'dart:convert';
import 'package:http/http.dart' as http;
import 'profile_api.dart';

class HistoryEntry {
  HistoryEntry(Map<String, dynamic> data)
    : id = data['id'] as String,
      reference = data['reference'] as String,
      kind = data['kind'] as String,
      direction = data['direction'] as String,
      amountMinor = data['amountMinor'] as String,
      currency = data['currency'] as String,
      postedAt = DateTime.parse(data['postedAt'] as String) {
    if (!RegExp(r'^[1-9]\d*$').hasMatch(amountMinor) ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency) ||
        !['credit', 'debit'].contains(direction) ||
        ![
          'deposit',
          'withdrawal',
          'transfer',
          'payment',
          'interest',
          'mortgage_repayment',
        ].contains(kind) ||
        !postedAt.isUtc ||
        id.isEmpty ||
        reference.isEmpty) {
      throw const FormatException('Invalid history entry.');
    }
  }
  final String id, reference, kind, direction, amountMinor, currency;
  final DateTime postedAt;
  String get kindLabel => switch (kind) {
    'deposit' => 'Deposit',
    'withdrawal' => 'Withdrawal',
    'transfer' => 'Transfer',
    'payment' => 'Payment',
    'interest' => 'Interest',
    _ => 'Mortgage repayment',
  };
  String get timeLabel {
    final time = postedAt.add(const Duration(hours: 7));
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${pad(time.month)}-${pad(time.day)} ${pad(time.hour)}:${pad(time.minute)} (UTC+07)';
  }
}

class HistoryPage {
  HistoryPage(this.entries, this.nextCursor);
  final List<HistoryEntry> entries;
  final String? nextCursor;
}

class AccountHistoryApi {
  AccountHistoryApi({required this.baseUrl, required this.client});
  final Uri baseUrl;
  final http.Client client;
  Future<HistoryPage> read(
    String token,
    String accountId,
    String month, {
    String? cursor,
  }) async {
    final request =
        http.Request(
            'GET',
            baseUrl
                .resolve(
                  'me/accounts/${Uri.encodeComponent(accountId)}/history',
                )
                .replace(queryParameters: {'month': month, 'cursor': ?cursor}),
          )
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer $token';
    final response = await client
        .send(request)
        .then((stream) async {
          final bytes = <int>[];
          await for (final chunk in stream.stream) {
            if (bytes.length + chunk.length > 65536) {
              throw const ApiException(ApiFailure.invalidResponse);
            }
            bytes.addAll(chunk);
          }
          return http.Response.bytes(bytes, stream.statusCode);
        })
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 401) {
      throw const ApiException(ApiFailure.unauthorized);
    }
    if (response.statusCode == 403) {
      throw const ApiException(ApiFailure.forbidden);
    }
    if (response.statusCode == 404) {
      throw const ApiException(ApiFailure.notFound);
    }
    if (response.statusCode != 200) {
      throw const ApiException(ApiFailure.unavailable);
    }
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (data['accountId'] != accountId ||
          data['month'] != month ||
          data['timeZone'] != 'Asia/Bangkok' ||
          data['entries'] is! List) {
        throw const FormatException();
      }
      final entries = (data['entries'] as List)
          .map((e) => HistoryEntry(e as Map<String, dynamic>))
          .toList();
      final next = data['nextCursor'];
      if (entries.length > 25 ||
          entries.map((e) => e.id).toSet().length != entries.length ||
          (next != null &&
              (next is! String ||
                  entries.length != 25 ||
                  next != entries.last.id))) {
        throw const FormatException();
      }
      return HistoryPage(entries, next as String?);
    } catch (_) {
      throw const ApiException(ApiFailure.invalidResponse);
    }
  }
}
