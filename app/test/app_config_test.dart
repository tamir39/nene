import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nene_app/config/app_config.dart';

const _publicKey = 'sb_publishable_abcdefghijklmnopqrstuv';

AppConfig parse({
  String api = 'https://api.example.test/api/v1',
  String supabase = 'https://project.supabase.co',
  String key = _publicKey,
  bool debug = false,
}) => AppConfig.parse(
  apiBaseUrl: api,
  supabaseUrl: supabase,
  supabasePublishableKey: key,
  allowLocalHttp: debug,
);

String legacyKey(String role) {
  final payload = base64Url.encode(utf8.encode(jsonEncode({'role': role})));
  return 'header.$payload.signature';
}

void main() {
  test('accepts public configuration with a versioned API path', () {
    final config = parse();
    expect(
      config.apiBaseUrl.resolve('me').toString(),
      'https://api.example.test/api/v1/me',
    );
  });

  test('fails closed with missing configuration or example placeholders', () {
    expect(() => parse(api: ''), throwsFormatException);
    expect(() => parse(supabase: ''), throwsFormatException);
    expect(() => parse(key: ''), throwsFormatException);
    expect(() => parse(key: 'replace-with-key'), throwsFormatException);
  });

  test('rejects database credentials and privileged Supabase keys', () {
    expect(
      () => parse(key: 'sb_secret_abcdefghijklmnopqrstuv'),
      throwsFormatException,
    );
    expect(() => parse(key: legacyKey('service_role')), throwsFormatException);
    expect(
      () => parse(key: 'postgresql://user:secret@localhost:5432/postgres'),
      throwsFormatException,
    );
    expect(() => parse(key: legacyKey('authenticated')), throwsFormatException);
    expect(() => parse(key: legacyKey('anon')), returnsNormally);
  });

  test('permits HTTP only for explicit debug loopback/emulator hosts', () {
    for (final host in ['localhost', '127.0.0.1', '10.0.2.2']) {
      expect(
        () => parse(api: 'http://$host:3000/api/v1'),
        throwsFormatException,
      );
      expect(
        () => parse(api: 'http://$host:3000/api/v1', debug: true),
        returnsNormally,
      );
    }
    expect(
      () => parse(api: 'http://192.168.1.20:3000/api/v1', debug: true),
      throwsFormatException,
    );
    expect(
      () => parse(supabase: 'http://example.com', debug: true),
      throwsFormatException,
    );
  });

  test('rejects credentials, query strings, fragments and wrong API paths', () {
    for (final url in [
      'https://user:secret@example.com/api/v1',
      'https://example.com/api/v1?token=secret',
      'https://example.com/api/v1#token',
      'https://example.com',
      'ftp://example.com/api/v1',
    ]) {
      expect(() => parse(api: url), throwsFormatException);
    }
  });
}
