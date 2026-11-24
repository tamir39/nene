import 'dart:async';
import 'package:flutter/material.dart';
import '../data/security_api.dart';
import '../data/session_owner.dart';
import 'customer_workspace.dart' show WorkspaceContent;

class SecurityManagementScreen extends StatefulWidget {
  const SecurityManagementScreen({
    super.key,
    required this.api,
    required this.onBack,
  });
  final SecurityApi api;
  final VoidCallback onBack;
  @override
  State<SecurityManagementScreen> createState() =>
      _SecurityManagementScreenState();
}

class _SecurityManagementScreenState extends State<SecurityManagementScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _management;
  String? _secret, _message;
  List<String>? _codes;
  final _code = TextEditingController();
  Timer? _expiry;
  bool _busy = false,
      _hidden = false,
      _loaded = false,
      _saved = false,
      _rotate = false;
  int _remaining = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _run(_load);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    _secret = null;
    _codes = null;
    _code.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() {
        _hidden = state != AppLifecycleState.resumed;
        if (_hidden) _code.clear();
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on SessionMutationRejected {
      if (mounted) {
        setState(
          () => _message =
              'Code not accepted or recently used. Wait for a new authenticator code, use another recovery code, or wait 15 minutes after too many attempts.',
        );
      }
    } catch (_) {
      _secret = null;
      _codes = null;
      if (mounted) {
        setState(
          () => _message =
              'This change could not be confirmed. Check status after signing in again. Do not repeat an uncertain code request.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    final data = await widget.api.managementStatus();
    if (!mounted) return;
    setState(() {
      final next = data['management'] as Map<String, dynamic>?;
      if (next?['requestId'] != _management?['requestId']) {
        _secret = null;
        _codes = null;
        _saved = false;
        _rotate = false;
      }
      _management = next;
      _remaining = data['remaining'] as int;
      _loaded = true;
      _expiry?.cancel();
      if (next != null) {
        final expires = DateTime.parse(next['expiresAt'] as String);
        final duration = expires.difference(DateTime.now());
        if (duration <= Duration.zero) {
          _secret = null;
          _codes = null;
        } else {
          _expiry = Timer(duration, () {
            if (mounted) {
              setState(() {
                _secret = null;
                _codes = null;
                _code.clear();
                _management?['expired'] = true;
              });
            }
          });
        }
      }
    });
  }

  Future<void> _start(String purpose) => _run(() async {
    await widget.api.managementCommand('start', {'purpose': purpose});
    await _load();
  });
  Future<void> _proof(String command) => _run(() async {
    final raw = _code.text.trim();
    _code.clear();
    final recovery =
        _management!['proofKind'] == 'recovery_code' &&
        ['prove', 'resume'].contains(command);
    if (!(recovery ? RegExp(r'^[A-Za-z0-9-]{8,128}$') : RegExp(r'^\d{6}$'))
        .hasMatch(raw)) {
      setState(
        () => _message = recovery
            ? 'Enter one saved recovery code.'
            : 'Enter a six-digit authenticator code.',
      );
      return;
    }
    final result = await widget.api.managementProof(
      command,
      _management!['requestId'] as String,
      _management!['revision'] as int,
      raw,
    );
    if (!mounted) return;
    if (command == 'issue-codes') {
      final values = (result['codes'] as List).cast<String>();
      if (values.isEmpty || values.any((code) => code.length > 128)) {
        throw const SessionCoordinationException();
      }
      _codes = values;
      _secret = null;
      _saved = false;
    }
    if (command == 'verify') _secret = null;
    await _load();
  });
  Future<void> _enroll() => _run(() async {
    final result = await widget.api.managementCommand('enroll', {
      'requestId': _management!['requestId'],
    });
    if (!mounted) return;
    _secret = result['secret'] as String;
    await _load();
  });
  Future<void> _finish() => _run(() async {
    _codes = null;
    _secret = null;
    await widget.api.finishManagement(_management!['requestId'] as String);
  });
  Future<void> _cancel() => _run(() async {
    await widget.api.managementCommand('cancel', {
      'requestId': _management!['requestId'],
    });
    _secret = null;
    _codes = null;
    try {
      await widget.api.owner.signOut();
    } catch (_) {
      /* local ownership already cleared */
    }
  });
  Widget _input(String label) => TextField(
    controller: _code,
    enabled: !_busy,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    keyboardType: label.contains('Recovery')
        ? TextInputType.text
        : TextInputType.number,
    decoration: InputDecoration(labelText: label),
  );
  Widget _button(String label, VoidCallback action, {bool enabled = true}) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: FilledButton(
          onPressed: _busy || _hidden || !enabled ? null : action,
          child: Text(label),
        ),
      );
  @override
  Widget build(BuildContext context) {
    final m = _management, step = m?['step'];
    final needsResume =
        m != null &&
        (m['sameSession'] != true ||
            m['expired'] == true ||
            (step == 'codes_shown' && _codes == null) ||
            step == 'verifying');
    final proofLabel = m?['proofKind'] == 'recovery_code'
        ? 'Recovery code'
        : m?['proofKind'] == 'new_authenticator'
        ? 'New authenticator code'
        : 'Current authenticator code';
    return WorkspaceContent(
      children: [
        Text(
          'Authenticator and recovery',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 16),
        const Text(
          'These actions change your security settings only. They never approve a payment. Start within five minutes of password sign-in.',
        ),
        if (_busy)
          const LinearProgressIndicator(semanticsLabel: 'Updating security'),
        if (_message != null)
          Semantics(liveRegion: true, child: Text(_message!)),
        if (_loaded && m == null) ...[
          Text('Unused recovery codes: $_remaining'),
          const Text(
            'Save backup codes before you lose access. If both your authenticator and codes are lost, recovery is blocked; an officer or password alone cannot reset it.',
          ),
          _button('Create / replace recovery codes', () => _start('codes')),
          _button('Replace authenticator', () => _start('replace')),
          _button('Use a recovery code', () => _start('recover')),
        ],
        if (m != null) ...[
          const SizedBox(height: 16),
          const Text(
            'Security change in progress. Transaction confirmation is restricted.',
          ),
          if (needsResume && m['canResume'] == true) ...[
            const Text(
              'Sign in again with your password, then prove access to continue. If a recovery code was consumed before a reply was lost, use another unused code. A verified replacement requires its new authenticator code. Lost backup-code displays require deliberate regeneration.',
            ),
            if (!_hidden) _input(proofLabel),
            _button('Resume with fresh proof', () => _proof('resume')),
          ] else if (step == 'proof') ...[
            Text(
              m['purpose'] == 'recover'
                  ? 'Use one previously saved recovery code to replace your lost authenticator.'
                  : 'Enter a fresh code from the authenticator you are replacing.',
            ),
            if (!_hidden) _input(proofLabel),
            _button('Verify access', () => _proof('prove')),
          ] else if (step == 'authorized') ...[
            const Text(
              'Access confirmed. Keep the old authenticator until the replacement is verified.',
            ),
            _button('Set up replacement', _enroll),
          ] else if (step == 'pending' && _secret != null) ...[
            const Text(
              'Add this private key to a new time-based Nene account in your authenticator.',
            ),
            if (!_hidden)
              SelectableText(
                _secret!,
                semanticsLabel: 'Private replacement setup key',
              ),
            if (!_hidden) _input('New authenticator code'),
            _button('Verify replacement', () => _proof('verify')),
          ] else if (step == 'verified') ...[
            const Text(
              'Wait for a new code from your active authenticator. This step retires the old authenticator when replacing and invalidates all previously unused recovery codes. New codes are displayed once.',
            ),
            CheckboxListTile(
              value: _rotate,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _rotate = value ?? false),
              title: const Text('Replace the previous recovery-code set.'),
            ),
            if (!_hidden)
              _input(
                m['purpose'] == 'codes'
                    ? 'Current authenticator code'
                    : 'New authenticator code',
              ),
            _button(
              'Create new recovery codes',
              () => _proof('issue-codes'),
              enabled: _rotate,
            ),
          ] else if (step == 'codes_shown' && _codes != null) ...[
            const Text(
              'Save these codes privately outside Nene. Each works once for authenticator recovery only. They cannot be retrieved again.',
            ),
            if (!_hidden)
              SelectableText(
                _codes!.join('\n'),
                semanticsLabel: 'Private recovery codes',
              ),
            CheckboxListTile(
              value: _saved,
              onChanged: _busy || _hidden
                  ? null
                  : (value) => setState(() => _saved = value ?? false),
              title: const Text('I saved my new recovery codes.'),
            ),
            _button('Finish and sign out everywhere', _finish, enabled: _saved),
          ] else if (step == 'finishing') ...[
            const Text(
              'Final sign-out needs confirmation. Sign in again, then finish. This will revoke existing sessions.',
            ),
            _button('Finish sign-out', _finish),
          ] else if (step == 'pending')
            const Text(
              'The private setup key is no longer available. Cancel this unverified replacement, sign in again and start over.',
            ),
          if (['proof', 'authorized', 'pending', 'cancelling'].contains(step))
            TextButton(
              onPressed: _busy ? null : _cancel,
              child: const Text('Cancel change and sign out'),
            ),
          if (['proving', 'enrolling', 'issuing', 'cancelling'].contains(step))
            const Text(
              'A provider request may have completed without confirmation. Security remains restricted. Check status; if it stays unresolved, ask the project team for synthetic-demo assistance. No reset or payment bypass is available.',
            ),
        ],
        TextButton(
          onPressed: _busy ? null : () => _run(_load),
          child: const Text('Check status'),
        ),
        TextButton(
          onPressed: _busy ? null : widget.onBack,
          child: const Text('Back to security status'),
        ),
      ],
    );
  }
}
