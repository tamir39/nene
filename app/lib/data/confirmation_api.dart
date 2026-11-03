import 'dart:convert';
import 'package:http/http.dart' as http;
import 'security_api.dart';
import 'session_owner.dart';

class ConfirmationApi {
  ConfirmationApi(this.security);
  final SecurityApi security;
  Future<Map<String, dynamic>> _request(
    String token,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final req =
        http.Request(
            body == null ? 'GET' : 'POST',
            security.baseUrl.resolve('me/transfer-confirmations/$path'),
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
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> review(
    String source,
    String destination,
    String amount,
  ) => security.owner.execute(
    (s) => _request(s.pair.accessToken, 'review', {
      'sourceAccountId': source,
      'destinationAccountNumber': destination,
      'amountMinor': amount,
    }),
  );
  Future<Map<String, dynamic>> status(String id) =>
      security.owner.execute((s) => _request(s.pair.accessToken, id));
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
          purpose: 'transaction-confirmation',
          securityRevision: review['revision'] as int,
        ),
        (s) async {
          final data = await _request(s.pair.accessToken, 'confirm', {
            'reviewToken': review['reviewToken'],
            'code': code,
          });
          response = data;
          // A duplicate returns status only, never replays a provider session pair.
          if (data['replay'] == true) throw const SessionMutationRejected();
          if (data['sent'] != false ||
              data['executionAvailable'] != false ||
              data['state'] != 'factor_confirmed') {
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
