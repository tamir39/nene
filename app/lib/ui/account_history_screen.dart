import 'package:flutter/material.dart';
import '../data/account_history_api.dart';
import '../data/banking_repository.dart';
import '../data/user_profile.dart';
import '../session_controller.dart';
import 'customer_workspace.dart' show WorkspaceContent;

class AccountHistoryScreen extends StatefulWidget {
  const AccountHistoryScreen({
    super.key,
    required this.session,
    required this.api,
    required this.account,
  });
  final SessionController session;
  final AccountHistoryApi api;
  final BankAccount account;
  @override
  State<AccountHistoryScreen> createState() => _AccountHistoryScreenState();
}

class _AccountHistoryScreenState extends State<AccountHistoryScreen> {
  final _month = TextEditingController();
  final _entries = <HistoryEntry>[];
  bool _busy = false, _loaded = false;
  String? _message, _cursor;
  String _activeMonth = '';
  @override
  void initState() {
    super.initState();
    _month.text = _currentMonth();
    _load();
  }

  String _currentMonth() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 7));
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _month.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    final month = more ? _activeMonth : _month.text.trim();
    if (!RegExp(r'^(20\d{2}|2100)-(0[1-9]|1[0-2])$').hasMatch(month)) {
      setState(
        () => _message = 'Enter a month from 2000-01 to 2100-12 (YYYY-MM).',
      );
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      if (!more) {
        _entries.clear();
        _cursor = null;
        _loaded = false;
        _activeMonth = month;
      }
    });
    try {
      final page = await widget.session.authorized(
        (token) => widget.api.read(
          token,
          widget.account.id,
          month,
          cursor: more ? _cursor : null,
        ),
        role: AppRole.customer,
      );
      if (mounted) {
        setState(() {
          // A malformed/cross-account response must never be displayed as money history.
          if (page.entries.any(
            (entry) =>
                entry.currency != widget.account.currency ||
                _entries.any((old) => old.id == entry.id),
          )) {
            throw const FormatException('Invalid history page.');
          }
          _entries.addAll(page.entries);
          _cursor = page.nextCursor;
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = more
              ? 'Could not load more transactions. Retry, or refresh this month.'
              : 'Could not load this account’s history. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      Text(
        'Transaction history',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      Text('${widget.account.typeLabel} · ${widget.account.accountNumber}'),
      if (widget.account.isDemo) const Text('Synthetic demo account'),
      const SizedBox(height: 16),
      const Text('Posted transactions only. Months and times use UTC+07.'),
      const SizedBox(height: 12),
      TextField(
        controller: _month,
        enabled: !_busy,
        keyboardType: TextInputType.datetime,
        decoration: const InputDecoration(labelText: 'Month (YYYY-MM)'),
        onSubmitted: (_) => _load(),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _busy ? null : () => _load(),
        child: const Text('Show month'),
      ),
      TextButton(
        onPressed: _busy
            ? null
            : () {
                _month.text = _currentMonth();
                _load();
              },
        child: const Text('Current month'),
      ),
      if (_busy)
        const LinearProgressIndicator(
          semanticsLabel: 'Loading transaction history',
        ),
      if (_message != null) Semantics(liveRegion: true, child: Text(_message!)),
      if (_loaded) ...[
        Text(
          'History for $_activeMonth',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (_entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              'No posted transactions in this month. Opening an account does not create a deposit or repayment.',
            ),
          ),
        for (final entry in _entries)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      entry.kindLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${entry.direction == 'credit' ? 'Money in +' : 'Money out −'}${widget.account.amountLabel(entry.amountMinor)}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(entry.timeLabel),
                    const Text('Posted'),
                    const SizedBox(height: 8),
                    const Text('Transaction reference'),
                    SelectableText(entry.reference),
                  ],
                ),
              ),
            ),
          ),
        if (_cursor != null)
          TextButton(
            onPressed: _busy ? null : () => _load(more: true),
            child: const Text('Load more'),
          ),
      ],
    ],
  );
}
