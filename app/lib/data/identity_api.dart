import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'identity_repository.dart';
import 'profile_api.dart';

/// Private images and metadata pass through NestJS, never Storage client APIs.
class IdentityApi implements IdentityRepository {
  IdentityApi({required Uri baseUrl, required http.Client client})
    : _baseUrl = baseUrl,
      _client = client;
  final Uri _baseUrl;
  final http.Client _client;

  Future<http.Response> _request(
    String token,
    String method,
    String path, {
    Map<String, Object?>? body,
    String? key,
    bool image = false,
  }) async {
    if (token.isEmpty) throw const ApiException(ApiFailure.unauthorized);
    try {
      final request = http.Request(method, _baseUrl.resolve(path))
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $token',
          'Accept': image ? 'image/jpeg, image/png' : 'application/json',
          if (body != null) 'Content-Type': 'application/json',
          'Idempotency-Key': ?key,
        });
      if (body != null) request.body = jsonEncode(body);
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw ApiException(switch (response.statusCode) {
          400 || 413 => ApiFailure.invalidInput,
          401 => ApiFailure.unauthorized,
          403 => ApiFailure.forbidden,
          404 => ApiFailure.notFound,
          409 => ApiFailure.conflict,
          _ => ApiFailure.unavailable,
        });
      }
      return response;
    } on http.ClientException {
      throw const ApiException(ApiFailure.unavailable);
    } on SocketException {
      throw const ApiException(ApiFailure.unavailable);
    } on TimeoutException {
      throw const ApiException(ApiFailure.unavailable);
    }
  }

  Future<IdentitySummary> _summary(
    String token,
    String method,
    String path, {
    Map<String, Object?>? body,
    String? key,
  }) async {
    final response = await _request(token, method, path, body: body, key: key);
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic>) throw const FormatException();
      return IdentitySummary.fromJson(data);
    } on FormatException {
      throw const ApiException(ApiFailure.invalidResponse);
    }
  }

  String _customerPath(String? customerId) => customerId == null
      ? 'me/identity'
      : 'officer/customers/${Uri.encodeComponent(customerId)}/identity';
  String _casePath(String caseId) =>
      'identity/cases/${Uri.encodeComponent(caseId)}';

  @override
  Future<IdentitySummary> getSummary(String token, {String? customerId}) =>
      _summary(token, 'GET', _customerPath(customerId));

  @override
  Future<IdentitySummary> start(
    String token, {
    String? customerId,
    required String noticeVersion,
    required String key,
  }) => _summary(
    token,
    'POST',
    '${_customerPath(customerId)}/cases',
    body: {'noticeVersion': noticeVersion, 'acknowledged': true},
    key: key,
  );

  @override
  Future<IdentitySummary> upload(
    String token,
    String caseId, {
    required int version,
    required String contentType,
    required Uint8List bytes,
    required String key,
  }) => _summary(
    token,
    'POST',
    '${_casePath(caseId)}/evidence',
    body: {
      'expectedVersion': version,
      'contentType': contentType,
      'dataBase64': base64Encode(bytes),
    },
    key: key,
  );

  @override
  Future<IdentitySummary> submit(
    String token,
    String caseId, {
    required int version,
    required String key,
  }) => _summary(
    token,
    'POST',
    '${_casePath(caseId)}/submit',
    body: {'expectedVersion': version},
    key: key,
  );

  @override
  Future<IdentitySummary> review(
    String token,
    String caseId, {
    required int version,
    required String action,
    required bool associationConfirmed,
    String? reason,
    required String key,
  }) => _summary(
    token,
    'POST',
    'officer/${_casePath(caseId)}/reviews',
    body: {
      'expectedVersion': version,
      'action': action,
      'associationConfirmed': associationConfirmed,
      'reason': reason,
    },
    key: key,
  );

  @override
  Future<Uint8List> getEvidence(
    String token,
    String caseId,
    String evidenceId,
  ) async {
    final response = await _request(
      token,
      'GET',
      '${_casePath(caseId)}/evidence/${Uri.encodeComponent(evidenceId)}',
      image: true,
    );
    final type = response.headers['content-type']?.split(';').first.trim();
    if (!{'image/jpeg', 'image/png'}.contains(type) ||
        response.bodyBytes.isEmpty ||
        response.bodyBytes.length > 10 * 1024 * 1024) {
      throw const ApiException(ApiFailure.invalidResponse);
    }
    return response.bodyBytes;
  }
}
