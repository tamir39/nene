import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'banking_repository.dart';
import 'profile_api.dart';
import 'user_profile.dart';

/// Banking data stays behind NestJS. No table/storage access or provider keys.
class BankingApi implements BankingRepository {
  BankingApi({required Uri baseUrl, required http.Client client})
    : _baseUrl = baseUrl,
      _client = client;

  final Uri _baseUrl;
  final http.Client _client;

  Future<T> _request<T>(
    String token,
    String method,
    String path,
    T Function(Map<String, dynamic>) parse, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    String? idempotencyKey,
  }) async {
    if (token.isEmpty) throw const ApiException(ApiFailure.unauthorized);
    try {
      final uri = _baseUrl.resolve(path).replace(queryParameters: query);
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
          if (body != null) 'Content-Type': 'application/json',
          'Idempotency-Key': ?idempotencyKey,
        });
      if (body != null) request.body = jsonEncode(body);
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw ApiException(switch (response.statusCode) {
          400 => ApiFailure.invalidInput,
          401 => ApiFailure.unauthorized,
          403 => ApiFailure.forbidden,
          404 => ApiFailure.notFound,
          409 =>
            _isConfirmedDuplicate(response)
                ? ApiFailure.customerExists
                : ApiFailure.conflict,
          _ => ApiFailure.unavailable,
        });
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid response.');
      }
      return parse(decoded);
    } on FormatException {
      throw const ApiException(ApiFailure.invalidResponse);
    } on http.ClientException {
      throw const ApiException(ApiFailure.unavailable);
    } on SocketException {
      throw const ApiException(ApiFailure.unavailable);
    } on TimeoutException {
      throw const ApiException(ApiFailure.unavailable);
    }
  }

  @override
  Future<List<BankAccount>> getAccounts(String token) => _request(
    token,
    'GET',
    'me/accounts',
    (json) => parseAccounts(json['accounts']),
  );

  @override
  Future<UserProfile> updateContact(
    String token, {
    required String? phone,
    required String? address,
  }) => _request(
    token,
    'PATCH',
    'me/contact',
    UserProfile.fromJson,
    body: {'phone': phone, 'address': address},
  );

  @override
  Future<CustomerDetail> createCustomer(
    String token,
    CustomerDraft draft,
    String idempotencyKey,
  ) => _request(
    token,
    'POST',
    'officer/customers',
    CustomerDetail.fromJson,
    body: draft.toJson(),
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<List<CustomerSummary>> findCustomers(String token, String query) =>
      _request(token, 'GET', 'officer/customers', (json) {
        final items = json['customers'];
        if (items is! List) {
          throw const FormatException('Missing customer list.');
        }
        return List.unmodifiable(
          items.map((entry) {
            if (entry is! Map<String, dynamic>) {
              throw const FormatException('Invalid customer.');
            }
            return CustomerSummary.fromJson(entry);
          }),
        );
      }, query: {'query': query});

  @override
  Future<CustomerDetail> getCustomer(String token, String id) => _request(
    token,
    'GET',
    'officer/customers/${Uri.encodeComponent(id)}',
    CustomerDetail.fromJson,
  );

  @override
  Future<CustomerDetail> updateCustomer(
    String token,
    String id, {
    required String displayName,
    required String? phone,
    required String? address,
    required String requestReason,
  }) => _request(
    token,
    'PATCH',
    'officer/customers/${Uri.encodeComponent(id)}',
    CustomerDetail.fromJson,
    body: {
      'displayName': displayName,
      'phone': phone,
      'address': address,
      'requestReason': requestReason,
    },
  );
}

bool _isConfirmedDuplicate(http.Response response) {
  try {
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body is Map<String, dynamic> &&
        body['code'] == 'CUSTOMER_EMAIL_EXISTS';
  } on FormatException {
    return false;
  }
}
