import 'dart:convert';
import 'package:http/http.dart' as http;
import 'profile_api.dart';

class DemoAccountsApi {
  DemoAccountsApi({required this.baseUrl, required this.client});
  final Uri baseUrl;
  final http.Client client;

  Future<void> create(
    String token,
    String customerId,
    String requestId,
    Map<String, dynamic> body,
  ) async {
    final request =
        http.Request(
            'POST',
            baseUrl.resolve(
              'officer/customers/${Uri.encodeComponent(customerId)}/demo-accounts',
            ),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            'Idempotency-Key': requestId,
          })
          ..body = jsonEncode(body);
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
    if (response.statusCode == 400) {
      throw const ApiException(ApiFailure.invalidInput);
    }
    if (response.statusCode == 404) {
      throw const ApiException(ApiFailure.notFound);
    }
    if (response.statusCode == 401) {
      throw const ApiException(ApiFailure.unauthorized);
    }
    if (response.statusCode == 403) {
      throw const ApiException(ApiFailure.forbidden);
    }
    if (response.statusCode == 409) {
      throw const ApiException(ApiFailure.conflict);
    }
    if (response.statusCode != 201) {
      throw const ApiException(ApiFailure.unavailable);
    }
    final data = jsonDecode(response.body);
    if (data is! Map ||
        data['customerId'] != customerId ||
        data['accountId'] is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(data['accountId'] as String)) {
      throw const ApiException(ApiFailure.invalidResponse);
    }
  }
}
