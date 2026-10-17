import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Public client settings only. Never place database or service keys here.
class AppConfig {
  const AppConfig._({
    required this.apiBaseUrl,
    required this.supabaseUrl,
    required this.supabasePublishableKey,
  });

  factory AppConfig.fromEnvironment() => AppConfig.parse(
    apiBaseUrl: const String.fromEnvironment('API_BASE_URL'),
    supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
    supabasePublishableKey: const String.fromEnvironment(
      'SUPABASE_PUBLISHABLE_KEY',
    ),
    allowLocalHttp: kDebugMode,
  );

  factory AppConfig.parse({
    required String apiBaseUrl,
    required String supabaseUrl,
    required String supabasePublishableKey,
    bool allowLocalHttp = false,
  }) {
    final api = _origin(apiBaseUrl, allowLocalHttp, api: true);
    final supabase = _origin(supabaseUrl, allowLocalHttp);
    final key = supabasePublishableKey.trim();
    if (!_isPublicKey(key)) {
      throw const FormatException('A public Supabase client key is required.');
    }
    return AppConfig._(
      apiBaseUrl: api,
      supabaseUrl: supabase,
      supabasePublishableKey: key,
    );
  }

  final Uri apiBaseUrl;
  final Uri supabaseUrl;
  final String supabasePublishableKey;

  static Uri _origin(String value, bool allowLocalHttp, {bool api = false}) {
    final uri = Uri.tryParse(value.trim());
    const localHosts = {'localhost', '127.0.0.1', '10.0.2.2'};
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (api
            ? uri.path != '/api/v1' && uri.path != '/api/v1/'
            : uri.path.isNotEmpty && uri.path != '/') ||
        !(uri.scheme == 'https' ||
            (allowLocalHttp &&
                uri.scheme == 'http' &&
                localHosts.contains(uri.host)))) {
      throw const FormatException('A valid secure service origin is required.');
    }
    return uri.replace(path: api ? '/api/v1/' : '');
  }

  static bool _isPublicKey(String key) {
    if (RegExp(r'^sb_publishable_[A-Za-z0-9_-]{16,}$').hasMatch(key)) {
      return true;
    }
    // Local Supabase can use the legacy anon JWT. Its role must be anon;
    // this is only an accidental-secret check, not signature verification.
    final segments = key.split('.');
    if (segments.length != 3) return false;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(segments[1]))),
      );
      return payload is Map<String, dynamic> && payload['role'] == 'anon';
    } on FormatException {
      return false;
    }
  }
}
