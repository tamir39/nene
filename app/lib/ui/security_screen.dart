import 'package:flutter/material.dart';
import '../data/security_api.dart';
import '../data/session_owner.dart';
import 'customer_workspace.dart' show WorkspaceContent;

class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key, required this.api});
  final SecurityApi api;
  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen>
    with WidgetsBindingObserver {
  String _state = 'loading';
  String? _secret, _requestId, _message;
  int _revision = 1;
  bool _busy = false, _hidden = false;
  final _code = TextEditingController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _secret = null;
    _code.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) setState(() => _hidden = state != AppLifecycleState.resumed);
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await task();
    } on SessionMutationRejected {
      if (mounted) {
        setState(
          () => _message =
              'That code was not accepted. Check your authenticator and try again.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'Unable to confirm this request. Check status. You may need to sign out and sign in again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    final data = await widget.api.status();
    if (mounted) {
      setState(() {
        _state = data['state'] as String;
        if (_state == 'ready') {
          _secret = null;
          _code.clear();
        }
      });
    }
  });
  Future<void> _start() => _run(() async {
    final data = await widget.api.start();
    if (mounted) {
      setState(() {
        _secret = data['secret'] as String;
        _requestId = data['requestId'] as String;
        _revision = data['revision'] as int;
        _state = 'pending';
      });
    }
  });
  Future<void> _verify() => _run(() async {
    final code = _code.text.trim();
    _code.clear();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _message = 'Enter the six-digit authenticator code.');
      return;
    }
    await widget.api.verify(_requestId!, _revision, code);
    _secret = null;
    final data = await widget.api.status();
    if (mounted) setState(() => _state = data['state'] as String);
  });
  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      Text(
        'Transaction security',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 16),
      const Text(
        'Set up an authenticator for future transaction confirmation. Setup does not approve a payment.',
      ),
      const SizedBox(height: 16),
      if (_busy)
        const LinearProgressIndicator(semanticsLabel: 'Checking authenticator'),
      if (_message != null) Text(_message!),
      if (_state == 'ready') ...[
        const Icon(Icons.verified_user_outlined, size: 40),
        const Text('Authenticator ready'),
        const Text(
          'Replacement and lost-access recovery are not available yet. Keep access to your authenticator. Payments remain unavailable.',
        ),
      ] else if (_state == 'not_set_up') ...[
        const Text(
          'Sign in within the last five minutes before starting. In your authenticator app, choose a time-based code.',
        ),
        FilledButton(
          onPressed: _busy ? null : _start,
          child: const Text('Set up authenticator'),
        ),
      ] else if (_state == 'pending' && _secret != null) ...[
        const Text(
          'Add an account named Nene in your authenticator using this setup key. Keep the key private.',
        ),
        if (!_hidden)
          SelectableText(
            _secret!,
            semanticsLabel: 'Private authenticator setup key',
          ),
        if (!_hidden)
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Authenticator code'),
          ),
        FilledButton(
          onPressed: _busy || _hidden ? null : _verify,
          child: const Text('Verify setup'),
        ),
      ] else if (_state != 'loading')
        const Text(
          'Setup needs attention. The setup key cannot be retrieved again. Replacement and recovery are not available in this version. Contact the project team for help with your synthetic demo account.',
        ),
      TextButton(
        onPressed: _busy ? null : _load,
        child: const Text('Check status'),
      ),
    ],
  );
}
