import 'package:flutter/foundation.dart';
import 'data/assistant_api.dart';
import 'data/user_profile.dart';
import 'session_controller.dart';

class AssistantMessage {
  const AssistantMessage(
    this.text, {
    this.isCustomer = false,
    this.actions = const [],
  });
  final String text;
  final bool isCustomer;
  final List<AssistantAction> actions;
}

class AssistantController extends ChangeNotifier {
  AssistantController({
    required SessionController session,
    required AssistantApi api,
  }) : _session = session,
       _api = api,
       _generation = session.generation {
    _session.addListener(_sessionChanged);
  }
  final SessionController _session;
  final AssistantApi _api;
  final int _generation;
  final _messages = <AssistantMessage>[];
  List<AssistantMessage> get messages => List.unmodifiable(_messages);
  bool busy = false, _disposed = false, _active = true;
  String? error, _context, _retry;
  int _revision = 0;
  bool get _current =>
      !_disposed &&
      _active &&
      _session.generation == _generation &&
      _session.status == SessionStatus.ready &&
      _session.profile?.role == AppRole.customer;
  void _sessionChanged() {
    if (!_current && !_disposed && _active) {
      _active = false;
      _revision++;
      busy = false;
      _messages.clear();
      _context = null;
      _retry = null;
      error = null;
      notifyListeners();
    }
  }

  Future<void> send(String text, {bool retry = false}) async {
    if (!_current || busy) return;
    final message = text.trim();
    if (message.isEmpty || message.length > 500) {
      error = 'Enter a question of up to 500 characters.';
      notifyListeners();
      return;
    }
    final revision = ++_revision;
    busy = true;
    error = null;
    _retry = message;
    if (!retry) {
      _messages.add(AssistantMessage(message, isCustomer: true));
      while (_messages.length > 39) {
        _messages.removeAt(0);
      }
    }
    notifyListeners();
    try {
      final reply = await _session.authorized(
        (token) => _api.ask(token, message, context: _context),
        role: AppRole.customer,
      );
      if (!_current || revision != _revision) return;
      _messages.add(AssistantMessage(reply.text, actions: reply.actions));
      _context = reply.context;
      _retry = null;
    } catch (_) {
      if (_current && revision == _revision) {
        error =
            'Could not get an answer. Try again. No transaction was created by chat.';
      }
    } finally {
      if (_current && revision == _revision) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> retry() async {
    if (_retry != null) await send(_retry!, retry: true);
  }

  void clear() {
    if (!_current) return;
    _revision++;
    busy = false;
    error = null;
    _messages.clear();
    _context = null;
    _retry = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _messages.clear();
    _context = null;
    _retry = null;
    _session.removeListener(_sessionChanged);
    super.dispose();
  }
}
