import 'dart:convert';
import 'package:http/http.dart' as http;
import 'security_api.dart';
import 'session_owner.dart';

class PaymentServiceOffer {
  const PaymentServiceOffer({
    required this.id,
    required this.name,
    required this.description,
    required this.amountMinor,
  });
  final String id, name, description, amountMinor;
  bool get isMovie =>
      const {'movie_matinee_v1', 'movie_evening_v1'}.contains(id);
  bool sameDetails(PaymentServiceOffer other) =>
      id == other.id &&
      name == other.name &&
      description == other.description &&
      amountMinor == other.amountMinor;
  factory PaymentServiceOffer.fromJson(Object? raw) {
    final data = _object(raw);
    final id = _text(data, 'id', 32);
    if (!{
          'electricity',
          'water',
          'phone',
          'movie_matinee_v1',
          'movie_evening_v1',
        }.contains(id) ||
        data['currency'] != 'VND') {
      throw const SessionCoordinationException();
    }
    return PaymentServiceOffer(
      id: id,
      name: _text(data, 'name', 120),
      description: _text(data, 'description', 600),
      amountMinor: _amount(data),
    );
  }
}

class PaymentConfiguration {
  const PaymentConfiguration(this.enabled, this.services);
  final bool enabled;
  final List<PaymentServiceOffer> services;
}

class PaymentPreview {
  const PaymentPreview(this.service, this.checkoutAvailable);
  final PaymentServiceOffer service;
  final bool checkoutAvailable;
}

class PaymentReview {
  const PaymentReview({
    required this.token,
    required this.requestId,
    required this.revision,
    required this.service,
    required this.expiresAt,
  });
  final String token, requestId;
  final int revision;
  final PaymentServiceOffer service;
  final DateTime expiresAt;
}

class PaymentOrder {
  const PaymentOrder({
    required this.id,
    required this.service,
    required this.state,
    required this.createdAt,
    required this.expiresAt,
  });
  final String id, state;
  final PaymentServiceOffer service;
  final DateTime createdAt, expiresAt;
  factory PaymentOrder.fromJson(Object? raw) {
    final data = _object(raw);
    final service = PaymentServiceOffer.fromJson(data['service']);
    final state = _text(data, 'state', 32);
    if (!{'awaiting_payment', 'paid', 'failed'}.contains(state) ||
        data['fulfillment'] != 'not_available' ||
        data['currency'] != 'VND' ||
        _amount(data) != service.amountMinor) {
      throw const SessionCoordinationException();
    }
    return PaymentOrder(
      id: _text(data, 'id', 128),
      service: service,
      state: state,
      createdAt: _date(data, 'createdAt'),
      expiresAt: _date(data, 'expiresAt'),
    );
  }
}

class PaymentStatus {
  const PaymentStatus({required this.state, this.order, this.checkoutUrl});
  final String state;
  final PaymentOrder? order;
  final Uri? checkoutUrl;
  factory PaymentStatus.fromJson(Map<String, dynamic> data, String expectedId) {
    final order = data['order'] == null
        ? null
        : PaymentOrder.fromJson(data['order']);
    final state = _text(data, 'state', 32);
    if (data['requestId'] != expectedId ||
        (order != null && (order.id != expectedId || order.state != state)) ||
        (order == null &&
            !{'checking', 'rejected', 'unknown'}.contains(state)) ||
        !{
          'awaiting_payment',
          'paid',
          'failed',
          'checking',
          'rejected',
          'unknown',
        }.contains(state)) {
      throw const SessionCoordinationException();
    }
    Uri? url;
    if (data['checkoutUrl'] != null) {
      url = checkedCheckoutUrl(data['checkoutUrl']);
      if (order == null || state != 'awaiting_payment') {
        throw const SessionCoordinationException();
      }
    }
    return PaymentStatus(state: state, order: order, checkoutUrl: url);
  }
}

/// Provider destinations are data, never arbitrary navigation instructions.
Uri checkedCheckoutUrl(Object? raw) {
  if (raw is! String || raw.length > 8192) {
    throw const SessionCoordinationException();
  }
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'sandbox.vnpayment.vn' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.path != '/paymentv2/vpcpay.html' ||
      uri.query.isEmpty) {
    throw const SessionCoordinationException();
  }
  return uri;
}

Map<String, dynamic> _object(Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw const SessionCoordinationException();
  }
  return raw;
}

String _text(Map<String, dynamic> data, String key, int limit) {
  final value = data[key];
  if (value is! String || value.isEmpty || value.length > limit) {
    throw const SessionCoordinationException();
  }
  return value;
}

String _amount(Map<String, dynamic> data) {
  final value = _text(data, 'amountMinor', 7);
  if (!RegExp(r'^[1-9]\d{0,6}$').hasMatch(value) ||
      BigInt.parse(value) >= BigInt.from(5000000)) {
    throw const SessionCoordinationException();
  }
  return value;
}

DateTime _date(Map<String, dynamic> data, String key) {
  final value = DateTime.tryParse(_text(data, key, 40));
  if (value == null) throw const SessionCoordinationException();
  return value;
}

class PaymentsApi {
  PaymentsApi(this.security);
  final SecurityApi security;

  Future<Map<String, dynamic>> _request(
    String token,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final req =
        http.Request(
            body == null ? 'GET' : 'POST',
            security.baseUrl.resolve('me/payments/$path'),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          });
    if (body != null) req.body = jsonEncode(body);
    final response = await security.client
        .send(req)
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
    if ([400, 404, 409, 429].contains(response.statusCode)) {
      throw const SessionMutationRejected();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const SessionCoordinationException();
    }
    return _object(jsonDecode(utf8.decode(response.bodyBytes)));
  }

  Future<PaymentConfiguration> configuration() =>
      security.owner.execute((s) async {
        final data = await _request(s.pair.accessToken, 'configuration');
        if (data['enabled'] is! bool ||
            data['fulfillment'] != 'not_available' ||
            data['services'] is! List ||
            (data['services'] as List).length > 5) {
          throw const SessionCoordinationException();
        }
        final services = (data['services'] as List)
            .map(PaymentServiceOffer.fromJson)
            .toList(growable: false);
        if (services.map((s) => s.id).toSet().length != services.length) {
          throw const SessionCoordinationException();
        }
        return PaymentConfiguration(data['enabled'] as bool, services);
      });

  Future<List<PaymentOrder>> recent() => security.owner.execute((s) async {
    final data = await _request(s.pair.accessToken, '');
    if (data['orders'] is! List || (data['orders'] as List).length > 20) {
      throw const SessionCoordinationException();
    }
    return (data['orders'] as List)
        .map(PaymentOrder.fromJson)
        .toList(growable: false);
  });

  Future<PaymentPreview> preview(String serviceId) =>
      security.owner.execute((s) async {
        final data = await _request(s.pair.accessToken, 'preview', {
          'serviceId': serviceId,
        });
        final service = PaymentServiceOffer.fromJson(data['service']);
        if (data.keys.any(
              (key) => !const {
                'service',
                'amountMinor',
                'currency',
                'checkoutAvailable',
                'fulfillment',
                'previewOnly',
              }.contains(key),
            ) ||
            data['previewOnly'] != true ||
            data['fulfillment'] != 'not_available' ||
            data['checkoutAvailable'] is! bool ||
            data['currency'] != 'VND' ||
            service.id != serviceId ||
            _amount(data) != service.amountMinor) {
          throw const SessionCoordinationException();
        }
        return PaymentPreview(service, data['checkoutAvailable'] as bool);
      });

  Future<PaymentReview> review(
    String serviceId, {
    PaymentServiceOffer? expected,
  }) => security.owner.execute((s) async {
    final data = await _request(s.pair.accessToken, 'review', {
      'serviceId': serviceId,
    });
    final service = PaymentServiceOffer.fromJson(data['service']);
    if (service.id != serviceId ||
        (expected != null && !service.sameDetails(expected)) ||
        data['revision'] is! int ||
        (data['revision'] as int) < 0 ||
        data['currency'] != 'VND' ||
        _amount(data) != service.amountMinor) {
      throw const SessionCoordinationException();
    }
    return PaymentReview(
      token: _text(data, 'reviewToken', 8192),
      requestId: _text(data, 'requestId', 128),
      revision: data['revision'] as int,
      service: service,
      expiresAt: _date(data, 'expiresAt'),
    );
  });

  Future<PaymentStatus> status(String id) => security.owner.execute((s) async {
    final data = await _request(s.pair.accessToken, Uri.encodeComponent(id));
    final status = PaymentStatus.fromJson(data, id);
    if (status.order != null && status.order!.id != id) {
      throw const SessionCoordinationException();
    }
    return status;
  });

  Future<PaymentStatus> confirm(PaymentReview review, String code) async {
    PaymentStatus? result;
    var replay = false;
    try {
      await security.owner.exchange(
        HandoffBinding(
          requestId: review.requestId,
          purpose: 'vnpay-checkout',
          securityRevision: review.revision,
        ),
        (s) async {
          final data = await _request(s.pair.accessToken, 'confirm', {
            'reviewToken': review.token,
            'code': code,
          });
          result = PaymentStatus.fromJson(data, review.requestId);
          final order = result!.order;
          if (order != null &&
              (order.id != review.requestId ||
                  !order.service.sameDetails(review.service))) {
            throw const SessionCoordinationException();
          }
          if (data['replay'] == true) {
            replay = true;
            throw const SessionMutationRejected();
          }
          if (data['replay'] != false || order == null) {
            throw const SessionCoordinationException();
          }
          return HandoffReply(
            pair: AuthPair(
              accessToken: _text(data, 'accessToken', 16384),
              refreshToken: _text(data, 'refreshToken', 16384),
            ),
            binding: HandoffBinding(
              requestId: _text(data, 'requestId', 128),
              purpose: _text(data, 'purpose', 32),
              securityRevision: data['revision'] as int,
            ),
          );
        },
      );
    } on SessionMutationRejected {
      if (!replay) rethrow;
    }
    return result!;
  }
}
