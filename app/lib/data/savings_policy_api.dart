import 'dart:convert';
import 'package:http/http.dart' as http;
import 'profile_api.dart';

class SavingsPolicy {
  const SavingsPolicy(this.annualRateBps, this.revision);
  final int annualRateBps, revision;
  factory SavingsPolicy.parse(Map<String, dynamic> data) {
    final rate = data['annualRateBps'], version = data['revision'];
    if (rate is! int ||
        rate < 0 ||
        rate > 2000 ||
        version is! int ||
        version < 1) {
      throw const ApiException(ApiFailure.invalidResponse);
    }
    return SavingsPolicy(rate, version);
  }
}

class SavingsPolicyApi {
  SavingsPolicyApi({required this.baseUrl, required this.client});
  final Uri baseUrl;
  final http.Client client;
  Future<SavingsPolicy> read(String token) => _call(token);
  Future<SavingsPolicy> save(
    String token,
    int rate,
    int revision,
    String reason,
  ) => _call(token, {
    'annualRateBps': rate,
    'revision': revision,
    'reason': reason,
  });
  Future<SavingsPolicy> _call(
    String token, [
    Map<String, dynamic>? body,
  ]) async {
    final request =
        http.Request(
            body == null ? 'GET' : 'PATCH',
            baseUrl.resolve('officer/savings-policy'),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          });
    if (body != null) request.body = jsonEncode(body);
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
    if (response.statusCode == 409) {
      throw const ApiException(ApiFailure.conflict);
    }
    if (response.statusCode != 200) {
      throw const ApiException(ApiFailure.unavailable);
    }
    return SavingsPolicy.parse(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }
}
