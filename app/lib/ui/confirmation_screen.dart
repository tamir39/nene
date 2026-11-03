import 'dart:async';
import 'package:flutter/material.dart';
import '../data/banking_repository.dart';
import '../data/confirmation_api.dart';
import '../data/session_owner.dart';
import 'customer_workspace.dart' show WorkspaceContent;

class ConfirmationScreen extends StatefulWidget {
  const ConfirmationScreen({
    super.key,
    required this.account,
    required this.api,
  });
  final BankAccount account;
  final ConfirmationApi api;
  @override
  State<ConfirmationScreen> createState() => _ConfirmationScreenState();
}

class _ConfirmationScreenState extends State<ConfirmationScreen>
    with WidgetsBindingObserver {
  final _destination = TextEditingController(),
      _amount = TextEditingController(),
      _code = TextEditingController();
  Map<String, dynamic>? _review;
  String? _state, _error;
  bool _busy = false, _hidden = false;
  Timer? _expiry;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    _destination.dispose();
    _amount.dispose();
    _code.dispose();
    _review = null;
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

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on SessionMutationRejected {
      if (mounted) {
        setState(
          () => _error =
              'Details or code were not accepted, or the code was already used. Check status, then start a new review with a fresh code. After too many attempts, wait 15 minutes.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _state = 'unknown';
          _code.clear();
          _error =
              'Confirmation could not be checked. No money was sent. Sign in again if needed; do not repeat an uncertain request.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare() => _run(() async {
    final security = await widget.api.security.status();
    if (!mounted) return;
    if (security['state'] != 'ready') {
      setState(
        () => _error =
            'Finish authenticator setup or recovery in My profile → Transaction security before reviewing a transfer.',
      );
      return;
    }
    if (!RegExp(r'^\d{12}$').hasMatch(_destination.text.trim()) ||
        !RegExp(r'^[1-9]\d{0,15}$').hasMatch(_amount.text.trim())) {
      setState(
        () => _error =
            'Enter a 12-digit Nene account number and a positive whole VND amount.',
      );
      return;
    }
    final data = await widget.api.review(
      widget.account.id,
      _destination.text.trim(),
      _amount.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _review = data;
      _state = 'review';
    });
    _expiry?.cancel();
    _expiry = Timer(
      DateTime.parse(data['expiresAt'] as String).difference(DateTime.now()),
      () {
        if (mounted) {
          setState(() {
            _state = 'expired';
            _code.clear();
          });
        }
      },
    );
  });
  Future<void> _confirm() => _run(() async {
    final code = _code.text.trim();
    _code.clear();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter a six-digit authenticator code.');
      return;
    }
    // A review permits one submitted proof. Definite rejection needs a new review.
    setState(() => _state = 'checking');
    final data = await widget.api.confirm(_review!, code);
    if (mounted) setState(() => _state = data['state'] as String);
  });
  Future<void> _status() => _run(() async {
    final data = await widget.api.status(_review!['requestId'] as String);
    if (mounted) setState(() => _state = data['state'] as String);
  });
  Future<void> _cancel() => _run(() async {
    final data = await widget.api.cancel(_review!['reviewToken'] as String);
    if (mounted) {
      setState(() {
        _state = data['state'] as String;
        _code.clear();
      });
    }
  });
  Future<void> _edit() => _run(() async {
    // Revoke the previous signed review before allowing edits or a new proof.
    await widget.api.cancel(_review!['reviewToken'] as String);
    if (mounted) {
      setState(() {
        _expiry?.cancel();
        _review = null;
        _state = null;
        _code.clear();
      });
    }
  });
  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      Text(
        'Transfer confirmation',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 16),
      const Text(
        'Confirmation preview only. No money will be sent. Identity checks and money movement are not available yet.',
      ),
      const SizedBox(height: 16),
      if (_busy)
        const LinearProgressIndicator(semanticsLabel: 'Checking confirmation'),
      if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
      if (_review == null) ...[
        Text('From ${widget.account.accountNumber}'),
        TextField(
          controller: _destination,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          maxLength: 12,
          decoration: const InputDecoration(
            labelText: 'Recipient Nene account number',
          ),
        ),
        TextField(
          controller: _amount,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Amount in VND',
            helperText: 'Whole VND only',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy || _hidden ? null : _prepare,
          child: const Text('Review confirmation'),
        ),
      ] else ...[
        Text('From ${_review!['sourceAccountNumber']}'),
        Text('To ${_review!['destinationAccountNumber']}'),
        Text(
          '${_review!['amountMinor']} VND',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const Text('Preview fee: 0 VND. This is not a transfer quote.'),
        if (_review!['sufficientFunds'] == false)
          const Text(
            'Insufficient funds for this amount. You can test the confirmation check, but this transfer cannot be sent.',
          ),
        const SizedBox(height: 16),
        if (_state == 'review') ...[
          const Text(
            'Check the accounts and amount. Enter a fresh code from your registered authenticator. A recovery code cannot confirm a transfer.',
          ),
          if (!_hidden)
            TextField(
              controller: _code,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Authenticator code',
              ),
            ),
          FilledButton(
            onPressed: _busy || _hidden ? null : _confirm,
            child: const Text('Check authenticator · do not send'),
          ),
        ] else ...[
          Semantics(
            liveRegion: true,
            child: Text(switch (_state) {
              'factor_confirmed' =>
                'Authenticator checked for these details. Transfer not sent.',
              'cancelled' => 'Confirmation cancelled. Transfer not sent.',
              'rejected' =>
                'Code not accepted. Start a new review with a fresh code.',
              'expired' => 'Review or confirmation expired. Transfer not sent.',
              'invalidated' =>
                'Security or sign-in changed. This confirmation is no longer valid.',
              'checking' =>
                'Confirmation not yet established. Check status before continuing.',
              _ => 'Confirmation uncertain. No money was sent.',
            }),
          ),
          TextButton(
            onPressed: _busy ? null : _status,
            child: const Text('Check confirmation status'),
          ),
        ],
        TextButton(
          onPressed: _busy ? null : _edit,
          child: const Text('Edit details / new review'),
        ),
        if (_state != 'cancelled')
          TextButton(
            onPressed: _busy ? null : _cancel,
            child: const Text('Cancel confirmation'),
          ),
      ],
    ],
  );
}
