import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'user_profile.dart';

enum ApiFailure { unauthorized, forbidden, unavailable, invalidResponse }

class ApiException implements Exception {
  const ApiException(this.failure);
  final ApiFailure failure;
}

abstract interface class ProfileRepository {
  Future<UserProfile> getProfile(String accessToken);
}

/// All application data comes from NestJS; the app never queries tables.
class ProfileApi implements ProfileRepository {
  ProfileApi({required Uri baseUrl, required http.Client client})
    : _baseUrl = baseUrl,
      _client = client;

  final Uri _baseUrl;
  final http.Client _client;

  @override
  Future<UserProfile> getProfile(String accessToken) async {
    if (accessToken.isEmpty) {
      throw const ApiException(ApiFailure.unauthorized);
    }
    try {
      // Do not follow redirects with a session bearer token.
      final request = http.Request('GET', _baseUrl.resolve('me'))
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $accessToken',
          'Accept': 'application/json',
        });
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 401) {
        throw const ApiException(ApiFailure.unauthorized);
      }
      if (response.statusCode == 403) {
        throw const ApiException(ApiFailure.forbidden);
      }
      if (response.statusCode != 200) {
        throw const ApiException(ApiFailure.unavailable);
      }
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map<String, dynamic>) {
        throw const ApiException(ApiFailure.invalidResponse);
      }
      return UserProfile.fromJson(body);
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
}
