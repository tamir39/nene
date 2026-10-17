import 'dart:async';

import 'package:http/http.dart' as http;

/// Bounds the complete Auth response before the SDK can install a session.
/// Auth exchanges are small JSON requests. A separate transport per request
/// lets a deadline close that connection without interrupting a later retry.
class BoundedAuthClient extends http.BaseClient {
  BoundedAuthClient({
    this.timeout = const Duration(seconds: 15),
    http.Client Function()? createClient,
  }) : _createClient = createClient ?? http.Client.new;

  final Duration timeout;
  final http.Client Function() _createClient;
  final Set<http.Client> _active = {};
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('Auth client is closed.', request.url);
    }
    final transport = _createClient();
    _active.add(transport);
    try {
      // Buffer inside the deadline: timing out only the headers would leave
      // a stalled response body blocking sign-in. The SDK never receives a
      // response after this future has failed, even if transport closes late.
      final response = await transport
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
      return http.StreamedResponse(
        Stream.value(response.bodyBytes),
        response.statusCode,
        contentLength: response.bodyBytes.length,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } on TimeoutException {
      throw http.ClientException('Auth request timed out.', request.url);
    } finally {
      _active.remove(transport);
      transport.close();
    }
  }

  @override
  void close() {
    _closed = true;
    for (final transport in _active) {
      transport.close();
    }
    _active.clear();
  }
}
