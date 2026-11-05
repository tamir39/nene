import 'dart:convert';
import 'package:http/http.dart' as http;
import 'profile_api.dart';

enum AssistantActivity { history, transfer, deposit, withdrawal }

class AssistantAction {
  const AssistantAction(this.activity, {this.month});
  factory AssistantAction.fromJson(Map<String, dynamic> data) {
    if (data.keys.any((key) => !['type', 'month'].contains(key))) {
      throw const FormatException('Unknown action field');
    }
    final activity = AssistantActivity.values.byName(data['type'] as String);
    final month = data['month'];
    if (activity == AssistantActivity.history) {
      if (month is! String ||
          !RegExp(r'^(20\d{2}|2100)-(0[1-9]|1[0-2])$').hasMatch(month)) {
        throw const FormatException('Invalid history month');
      }
    } else if (data.containsKey('month')) {
      throw const FormatException('Unexpected month');
    }
    return AssistantAction(activity, month: month as String?);
  }
  final AssistantActivity activity;
  final String? month;
  String get label => switch (activity) {
    AssistantActivity.history => 'View history · $month',
    AssistantActivity.transfer => 'Open demo transfer',
    AssistantActivity.deposit => 'Open demo deposit',
    AssistantActivity.withdrawal => 'Open demo withdrawal',
  };
}

class AssistantReply {
  AssistantReply.fromJson(Map<String, dynamic> data)
    : text = data['reply'] as String,
      actions = (data['actions'] as List)
          .map((a) => AssistantAction.fromJson(a as Map<String, dynamic>))
          .toList(),
      context = data['context'] as String? {
    if (data.keys.any(
          (key) => !['reply', 'actions', 'context'].contains(key),
        ) ||
        text.trim().isEmpty ||
        text.length > 1400 ||
        actions.length > 4 ||
        (context != null && context != 'history_month')) {
      throw const FormatException('Invalid reply');
    }
  }
  final String text;
  final List<AssistantAction> actions;
  final String? context;
}

class AssistantApi {
  AssistantApi({required this.baseUrl, required this.client});
  final Uri baseUrl;
  final http.Client client;
  Future<AssistantReply> ask(
    String token,
    String message, {
    String? context,
  }) async {
    final req = http.Request('POST', baseUrl.resolve('me/assistant/messages'))
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode({'message': message, 'context': ?context});
    final response = await client
        .send(req)
        .then((stream) async {
          final bytes = <int>[];
          await for (final chunk in stream.stream) {
            if (bytes.length + chunk.length > 16384) {
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
    if (response.statusCode != 200) {
      throw const ApiException(ApiFailure.unavailable);
    }
    try {
      return AssistantReply.fromJson(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    } catch (_) {
      throw const ApiException(ApiFailure.invalidResponse);
    }
  }
}
