import 'package:flutter/material.dart';
import '../data/account_history_api.dart';
import '../data/banking_repository.dart';
import '../data/user_profile.dart';
import '../session_controller.dart';
import 'customer_workspace.dart' show WorkspaceContent;
import 'nene_brand.dart';
import 'nene_components.dart' show SectionTitle;

class AccountHistoryScreen extends StatefulWidget {
  const AccountHistoryScreen({
    super.key,
    required this.session,
    required this.api,
    required this.account,
    this.initialMonth,
  });
  final SessionController session;
  final AccountHistoryApi api;
  final BankAccount account;
  final String? initialMonth;
  @override
  State<AccountHistoryScreen> createState() => _AccountHistoryScreenState();
}

class _AccountHistoryScreenState extends State<AccountHistoryScreen> {
  static final _monthPattern = RegExp(r'^(20\d{2}|2100)-(0[1-9]|1[0-2])$');
  final _month = TextEditingController();
  final _entries = <HistoryEntry>[];
  bool _busy = false, _loaded = false;
  // Places each message beside the control that resolves it.
  _Failure? _failure;
  String? _message, _cursor;
  String _activeMonth = '';
  @override
  void initState() {
    super.initState();
    _month.text = widget.initialMonth ?? _currentMonth();
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

  /// Steps from the typed (or last shown) month; [_load] still validates it.
  void _shift(int delta) {
    final typed = _month.text.trim();
    final base = _monthPattern.hasMatch(typed)
        ? typed
        : _activeMonth.isNotEmpty
        ? _activeMonth
        : _currentMonth();
    final index =
        int.parse(base.substring(0, 4)) * 12 +
        int.parse(base.substring(5)) -
        1 +
        delta;
    _month.text =
        '${index ~/ 12}-${(index % 12 + 1).toString().padLeft(2, '0')}';
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    final month = more ? _activeMonth : _month.text.trim();
    if (!_monthPattern.hasMatch(month)) {
      setState(() {
        _message = 'Enter a month from 2000-01 to 2100-12 (YYYY-MM).';
        _failure = _Failure.invalidMonth;
      });
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
        setState(() {
          _message = more
              ? 'Could not load more transactions. Retry, or refresh this month.'
              : 'Could not load this account’s history. Try again.';
          _failure = more ? _Failure.more : _Failure.month;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final message = _message == null
        ? null
        : Semantics(
            liveRegion: true,
            child: _Alert(
              _message!,
              action: _failure == _Failure.month
                  ? TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 40),
                      ),
                      onPressed: _busy ? null : () => _load(),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Try again'),
                    )
                  : null,
            ),
          );
    return WorkspaceContent(
      children: [
        Text(
          'Transaction history',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        _AccountStrip(widget.account),
        const SizedBox(height: 16),
        _Surface(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Previous month',
                    onPressed: _busy ? null : () => _shift(-1),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: _month,
                      enabled: !_busy,
                      keyboardType: TextInputType.datetime,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        fontFeatures: neneTabularFigures,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Month (YYYY-MM)',
                        floatingLabelAlignment: FloatingLabelAlignment.center,
                      ),
                      onSubmitted: (_) => _load(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Next month',
                    onPressed: _busy ? null : () => _shift(1),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FilledButton(
                  onPressed: _busy ? null : () => _load(),
                  child: const Text('Show month'),
                ),
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
            ],
          ),
        ),
        const SizedBox(height: 10),
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.schedule_rounded, size: 16, color: NeneColors.muted),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Posted transactions only. Months and times use UTC+07.',
                style: TextStyle(color: NeneColors.muted, fontSize: 12.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 4,
          child: _busy
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: const LinearProgressIndicator(
                    semanticsLabel: 'Loading transaction history',
                  ),
                )
              : null,
        ),
        if (message != null && _failure != _Failure.more) ...[
          const SizedBox(height: 12),
          message,
        ],
        if (_loaded) ...[
          const SizedBox(height: 16),
          SectionTitle('History for $_activeMonth'),
          if (_entries.isEmpty)
            _Surface(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
              child: Column(
                children: [
                  const _Badge(
                    Icons.receipt_long_outlined,
                    background: NeneColors.pale,
                    foreground: NeneColors.action,
                    size: 56,
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'No posted transactions in this month. Opening an account does not create a deposit or repayment.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: NeneColors.muted),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _busy ? null : () => _shift(-1),
                    icon: const Icon(Icons.chevron_left_rounded, size: 18),
                    label: const Text('View previous month'),
                  ),
                ],
              ),
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final (index, entry) in _entries.indexed) ...[
                    if (index > 0) const Divider(indent: 68),
                    _EntryRow(entry, account: widget.account),
                  ],
                ],
              ),
            ),
          if (message != null && _failure == _Failure.more) ...[
            const SizedBox(height: 12),
            message,
          ],
          if (_cursor != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _load(more: true),
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more_rounded),
              label: const Text('Load more'),
            ),
          ],
        ],
      ],
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({required this.child, required this.padding});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: NeneColors.line),
    ),
    child: child,
  );
}

class _Badge extends StatelessWidget {
  const _Badge(
    this.icon, {
    required this.background,
    required this.foreground,
    this.size = 44,
    this.semanticLabel,
  });
  final IconData icon;
  final Color background, foreground;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(size * .32),
    ),
    child: Icon(
      icon,
      color: foreground,
      size: size * .5,
      semanticLabel: semanticLabel,
    ),
  );
}

class _AccountStrip extends StatelessWidget {
  const _AccountStrip(this.account);
  final BankAccount account;

  @override
  Widget build(BuildContext context) => _Surface(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        _Badge(
          switch (account.type) {
            'saving' => Icons.savings_outlined,
            'mortgage' => Icons.home_work_outlined,
            _ => Icons.account_balance_wallet_outlined,
          },
          background: NeneColors.pale,
          foreground: NeneColors.action,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                account.typeLabel,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                account.accountNumber,
                style: const TextStyle(
                  color: NeneColors.muted,
                  fontSize: 13.5,
                  letterSpacing: .8,
                  fontFeatures: neneTabularFigures,
                ),
              ),
              if (account.isDemo) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: NeneColors.apricotSoft,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: const Text(
                    'Synthetic demo account',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: NeneColors.deep,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

/// Which control a message belongs beside.
enum _Failure { invalidMonth, month, more }

class _Alert extends StatelessWidget {
  const _Alert(this.text, {this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.fromLTRB(14, 14, 14, action == null ? 14 : 4),
    decoration: BoxDecoration(
      color: const Color(0xFFFBEAEA),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.error_outline_rounded,
          size: 20,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                style: const TextStyle(fontSize: 13.5, color: NeneColors.ink),
              ),
              ?action,
            ],
          ),
        ),
      ],
    ),
  );
}

/// One statement line: direction icon, description, time, reference and a
/// signed amount (money in is green, money out stays ink).
class _EntryRow extends StatelessWidget {
  const _EntryRow(this.entry, {required this.account});
  final HistoryEntry entry;
  final BankAccount account;

  @override
  Widget build(BuildContext context) {
    final credit = entry.direction == 'credit';
    const small = TextStyle(color: NeneColors.muted, fontSize: 12.5);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Badge(
            credit ? Icons.south_west_rounded : Icons.north_east_rounded,
            background: credit ? const Color(0xFFE3F3EA) : NeneColors.pale,
            foreground: credit ? NeneColors.positive : NeneColors.action,
            size: 40,
            semanticLabel: credit ? 'Money in' : 'Money out',
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The amount keeps its natural width but never squeezes the
                // description below 40%, so large text wraps instead of
                // overflowing.
                LayoutBuilder(
                  builder: (context, constraints) => Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          entry.kindLabel,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth * .6,
                        ),
                        child: Text(
                          '${credit ? '+' : '−'}${account.amountLabel(entry.amountMinor)}',
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: credit
                                ? NeneColors.positive
                                : NeneColors.ink,
                            fontFeatures: neneTabularFigures,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${entry.timeLabel} · Posted',
                  style: small.copyWith(fontFeatures: neneTabularFigures),
                ),
                const SizedBox(height: 8),
                Text(
                  'Transaction reference',
                  style: small.copyWith(fontSize: 11.5),
                ),
                SelectableText(
                  entry.reference,
                  style: small.copyWith(
                    fontSize: 12,
                    color: NeneColors.ink,
                    fontFeatures: neneTabularFigures,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
