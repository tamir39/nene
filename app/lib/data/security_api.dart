import 'dart:convert';
import 'package:http/http.dart' as http;
import 'session_owner.dart';

class SecurityApi {
  SecurityApi({
    required this.baseUrl,
    required this.client,
    required this.owner,
  });
  final Uri baseUrl;
  final http.Client client;
  final SessionOwner owner;
  Future<Map<String, dynamic>> request(
    String token,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final request =
        http.Request(
            body == null ? 'GET' : 'POST',
            baseUrl.resolve('me/security$path'),
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
              throw const SessionCoordinationException();
            }
            bytes.addAll(chunk);
          }
          return http.Response.bytes(bytes, stream.statusCode);
        })
        .timeout(const Duration(seconds: 15));
    if (path == '/verify' && response.statusCode == 400) {
      throw const SessionMutationRejected();
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        response.bodyBytes.length > 65536) {
      throw const SessionCoordinationException();
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> status() =>
      request(owner.session!.pair.accessToken, '');
  Future<Map<String, dynamic>> start() =>
      request(owner.session!.pair.accessToken, '/setup', {});
  Future<void> verify(String requestId, int revision, String code) =>
      owner.exchange(
        HandoffBinding(
          requestId: requestId,
          purpose: 'enroll',
          securityRevision: revision,
        ),
        (session) async {
          final data = await request(session.pair.accessToken, '/verify', {
            'requestId': requestId,
            'code': code,
          });
          return HandoffReply(
            pair: AuthPair(
              accessToken: data['accessToken'] as String,
              refreshToken: data['refreshToken'] as String,
            ),
            binding: HandoffBinding(
              requestId: data['requestId'] as String,
              purpose: 'enroll',
              securityRevision: data['revision'] as int,
            ),
          );
        },
      );
}
