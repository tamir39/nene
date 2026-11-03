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
  bool _enabled = false;
  List<Map<String, dynamic>> _recent = [];
  bool get _send => widget.api.sendMoney;
  bool get _cash => widget.api.cashOperation != null;
  bool get _deposit => widget.api.cashOperation == CashOperation.deposit;
  String? _cashBalance;
  String get _noun =>
      _cash ? (_deposit ? 'Deposit' : 'Withdrawal') : 'Transfer';
  String get _confirmLabel => _cash
      ? (_deposit ? 'Confirm demo deposit' : 'Confirm demo withdrawal')
      : 'Confirm and send demo funds';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_send) _run(_loadRecent);
  }

  Future<void> _loadRecent() async {
    final config = await widget.api.configuration();
    final data = await widget.api.recent();
    if (mounted) {
      setState(() {
        _enabled = config['enabled'] == true;
        _cashBalance = config['cashBalanceMinor'] as String?;
        _recent = (data[_cash ? 'operations' : 'transfers'] as List)
            .cast<Map<String, dynamic>>();
      });
    }
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
          () => _error = _send
              ? 'Check available funds, prepared demo accounts, an unexpired accepted reference and an amount below 5,000,000 VND. For a rejected code, check status before a new review; wait for a fresh code or 15 minutes after too many attempts.'
              : 'Details or code were not accepted, or the code was already used. Check status, then start a new review with a fresh code. After too many attempts, wait 15 minutes.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _state = 'unknown';
          _code.clear();
          _error = _send
              ? _cash
                    ? 'Outcome is unconfirmed. Check recent operations or account history after signing in. Do not repeat the operation until the outcome is known.'
                    : 'Transfer outcome is unconfirmed. Check recent transfers or account history after signing in. Do not send it again until the outcome is known.'
              : 'Confirmation could not be checked. No money was sent. Sign in again if needed; do not repeat an uncertain request.';
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
            'Finish authenticator setup or recovery in My profile → Transaction security before reviewing a transaction.',
      );
      return;
    }
    if ((!_cash && !RegExp(r'^\d{12}$').hasMatch(_destination.text.trim())) ||
        !RegExp(r'^[1-9]\d{0,15}$').hasMatch(_amount.text.trim())) {
      setState(
        () => _error = _cash
            ? 'Enter a positive whole VND amount.'
            : 'Enter a 12-digit Nene account number and a positive whole VND amount.',
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
            if (_state == 'posted') return;
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
    if (data['state'] == 'posted') _expiry?.cancel();
    if (mounted) setState(() => _state = data['state'] as String);
  });
  Future<void> _status() => _run(() async {
    final data = await widget.api.status(_review!['requestId'] as String);
    if (data['state'] == 'posted') _expiry?.cancel();
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
        _cash
            ? (_deposit ? 'Deposit demo funds' : 'Withdraw demo funds')
            : _send
            ? 'Transfer demo funds'
            : 'Transfer confirmation',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 16),
      Text(
        _cash
            ? 'Local cash simulation only. Deposits move your limited simulated cash into this account; withdrawals move it back. No real cash or external payment is involved. Amounts of 5,000,000 VND or more are blocked.'
            : _send
            ? 'Synthetic local funds only. Sending changes both demo balances and records a transfer. Amounts of 5,000,000 VND or more are blocked until actual face comparison is available.'
            : 'Confirmation preview only. No money will be sent. Identity checks and money movement are not available yet.',
      ),
      const SizedBox(height: 16),
      if (_busy)
        const LinearProgressIndicator(semanticsLabel: 'Checking confirmation'),
      if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
      if (_review == null) ...[
        if (_send) ...[
          if (!_enabled && !_busy)
            Text(
              _cash
                  ? 'This local cash demo is not enabled. Ask the project team to prepare the demo account.'
                  : 'This local transfer demo is not enabled. Ask the project team to prepare the demo accounts.',
            ),
          if (_recent.isNotEmpty) ...[
            Text(
              _cash
                  ? 'Recent ${_noun.toLowerCase()} attempts'
                  : 'Recent transfer attempts',
            ),
            for (final item in _recent)
              ListTile(
                title: Text(
                  item['state'] == 'posted'
                      ? '${_cash ? (_deposit ? 'Deposited' : 'Withdrawn') : 'Sent'} ${(item['receipt'] as Map)['amountMinor']} VND · demo funds'
                      : '${item['state']} · check before sending again',
                ),
                subtitle: Text(item['requestId'] as String),
              ),
          ],
          TextButton(
            onPressed: _busy ? null : () => _run(_loadRecent),
            child: Text(
              _cash ? 'Refresh recent operations' : 'Refresh recent transfers',
            ),
          ),
        ],
        if (_cash)
          Text(
            'Simulated cash outside accounts: ${_cashBalance ?? 'not prepared'}${_cashBalance == null ? '' : ' VND'}',
          ),
        Text('${_cash ? 'Account' : 'From'} ${widget.account.accountNumber}'),
        if (!_cash)
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
          onPressed: _busy || _hidden || (_send && !_enabled) ? null : _prepare,
          child: const Text('Review confirmation'),
        ),
      ] else ...[
        if (_cash) ...[
          Text(
            _deposit
                ? 'From simulated cash'
                : 'From account ${_review!['accountNumber']}',
          ),
          Text(
            _deposit
                ? 'To account ${_review!['accountNumber']}'
                : 'To simulated cash',
          ),
        ] else ...[
          Text('From ${_review!['sourceAccountNumber']}'),
          Text('To ${_review!['destinationAccountNumber']}'),
        ],
        Text(
          '${_review!['amountMinor']} VND',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(
          _send
              ? 'Demo ${_noun.toLowerCase()} fee: 0 VND.'
              : 'Preview fee: 0 VND. This is not a transfer quote.',
        ),
        if (_review!['sufficientFunds'] == false)
          const Text(
            'Insufficient funds for this amount. You can test the confirmation check, but this transfer cannot be sent.',
          ),
        const SizedBox(height: 16),
        if (_state == 'review') ...[
          const Text(
            'Check the accounts and amount. Enter a fresh code from your registered authenticator. A recovery code cannot confirm this operation.',
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
            child: Text(
              _send ? _confirmLabel : 'Check authenticator · do not send',
            ),
          ),
        ] else ...[
          Semantics(
            liveRegion: true,
            child: Text(switch (_state) {
              'posted' =>
                _cash
                    ? 'Demo ${_noun.toLowerCase()} completed. Account balance and history were updated. No real cash moved.'
                    : 'Demo transfer sent. Balances and transaction history were updated.',
              'factor_confirmed' =>
                'Authenticator checked for these details. Transfer not sent.',
              'cancelled' =>
                _cash
                    ? 'Confirmation cancelled. No deposit or withdrawal was posted.'
                    : 'Confirmation cancelled. Transfer not sent.',
              'rejected' =>
                'Code not accepted. Start a new review with a fresh code.',
              'expired' =>
                _send
                    ? 'Review expired. Check recent operations or history for any submitted transaction.'
                    : 'Review or confirmation expired. Transfer not sent.',
              'invalidated' =>
                'Security or sign-in changed. This confirmation is no longer valid.',
              'checking' =>
                'Confirmation not yet established. Check status before continuing.',
              _ =>
                _send
                    ? _cash
                          ? 'Outcome unconfirmed. Check recent operations/history before trying again.'
                          : 'Transfer outcome unconfirmed. Check recent transfers/history before sending again.'
                    : 'Confirmation uncertain. No money was sent.',
            }),
          ),
          TextButton(
            onPressed: _busy ? null : _status,
            child: const Text('Check confirmation status'),
          ),
        ],
        if (_state != 'posted')
          TextButton(
            onPressed: _busy ? null : _edit,
            child: const Text('Edit details / new review'),
          ),
        if (_state == 'posted')
          TextButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    setState(() {
                      _review = null;
                      _state = null;
                    });
                    await _loadRecent();
                  }),
            child: Text(
              _cash
                  ? 'Start another ${_noun.toLowerCase()}'
                  : 'Start another transfer',
            ),
          ),
        if (_state != 'cancelled' && _state != 'posted')
          TextButton(
            onPressed: _busy ? null : _cancel,
            child: const Text('Cancel confirmation'),
          ),
      ],
    ],
  );
}
