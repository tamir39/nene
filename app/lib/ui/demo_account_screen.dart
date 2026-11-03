import 'dart:math';
import 'package:flutter/material.dart';
import '../data/demo_accounts_api.dart';
import '../data/profile_api.dart';
import '../data/user_profile.dart';
import '../session_controller.dart';
import 'customer_workspace.dart' show WorkspaceContent;

class DemoAccountScreen extends StatefulWidget {
  const DemoAccountScreen({
    super.key,
    required this.session,
    required this.api,
    required this.customerId,
    required this.customerName,
    required this.onDone,
  });
  final SessionController session;
  final DemoAccountsApi api;
  final String customerId, customerName;
  final VoidCallback onDone;
  @override
  State<DemoAccountScreen> createState() => _DemoAccountScreenState();
}

class _DemoAccountScreenState extends State<DemoAccountScreen> {
  final _reason = TextEditingController(),
      _principal = TextEditingController(),
      _months = TextEditingController(),
      _date = TextEditingController();
  String _type = 'saving';
  bool _confirmed = false, _busy = false, _blocked = false;
  String? _message, _key;
  Map<String, dynamic>? _attempt;
  bool get _editable => !_busy && _attempt == null;
  @override
  void dispose() {
    for (final controller in [_reason, _principal, _months, _date]) {
      controller.dispose();
    }
    super.dispose();
  }

  String _newKey() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _submit() async {
    if (_busy || _blocked) return;
    FocusScope.of(context).unfocus();
    if (_attempt == null) {
      final reason = _reason.text.trim(),
          raw = _principal.text.trim(),
          date = _date.text.trim();
      final months = int.tryParse(_months.text.trim());
      final principal = BigInt.tryParse(raw);
      final parsedDate = DateTime.tryParse('${date}T00:00:00Z');
      if (!_confirmed ||
          reason.length < 5 ||
          reason.length > 500 ||
          RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(reason) ||
          (_type == 'mortgage' &&
              (!RegExp(r'^[1-9]\d{0,12}$').hasMatch(raw) ||
                  principal == null ||
                  principal > BigInt.from(1000000000000) ||
                  months == null ||
                  months < 1 ||
                  months > 360 ||
                  principal < BigInt.from(months) ||
                  !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
                  parsedDate == null ||
                  parsedDate.toIso8601String().substring(0, 10) != date ||
                  date.compareTo('2000-01-01') < 0 ||
                  date.compareTo('2100-12-31') > 0))) {
        setState(
          () => _message =
              'Confirm synthetic data and enter a reason of 5–500 characters. For a mortgage, use whole VND from the term length up to 1 trillion, 1–360 months and a valid date (2000–2100).',
        );
        return;
      }
      _attempt = Map.unmodifiable({
        'type': _type,
        'reason': reason,
        'syntheticConfirmed': true,
        if (_type == 'mortgage') ...{
          'principalMinor': raw,
          'termMonths': months,
          'firstDueOn': date,
        },
      });
      _key = _newKey();
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.session.authorized(
        (token) =>
            widget.api.create(token, widget.customerId, _key!, _attempt!),
        role: AppRole.officer,
      );
      if (mounted) widget.onDone();
    } catch (error) {
      if (mounted) {
        setState(() {
          if (error is ApiException &&
              error.failure == ApiFailure.invalidInput) {
            _attempt = null;
            _key = null;
            _message = 'Check the account details and try again.';
            return;
          }
          _blocked =
              error is ApiException &&
              [
                ApiFailure.conflict,
                ApiFailure.forbidden,
                ApiFailure.notFound,
              ].contains(error.failure);
          _message = _blocked
              ? 'This account could not be added. Check the customer: only local synthetic customers are allowed, with one demo account of each type.'
              : 'Creation could not be confirmed. Retry the same request, or check the customer before starting again. The details are kept unchanged for a safe retry.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      Text(
        'Add demo account',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      Text('Customer: ${widget.customerName}'),
      const SizedBox(height: 16),
      const Text(
        'Local synthetic customers only (.invalid or .test email). One demo savings and one demo mortgage account per customer. Opening balance is 0 VND; no money is moved.',
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        initialValue: _type,
        decoration: const InputDecoration(labelText: 'Account type'),
        items: const [
          DropdownMenuItem(value: 'saving', child: Text('Savings')),
          DropdownMenuItem(value: 'mortgage', child: Text('Mortgage')),
        ],
        onChanged: _editable ? (value) => setState(() => _type = value!) : null,
      ),
      if (_type == 'mortgage') ...[
        const SizedBox(height: 12),
        const Text(
          'Sample schedule at 0% interest for testing views. This does not issue a loan or create a real repayment obligation. Regular monthly amounts round down to whole VND; the last payment would include the remainder.',
        ),
        TextField(
          controller: _principal,
          enabled: _editable,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Sample principal (VND)',
          ),
        ),
        TextField(
          controller: _months,
          enabled: _editable,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Term (months)'),
        ),
        TextField(
          controller: _date,
          enabled: _editable,
          keyboardType: TextInputType.datetime,
          decoration: const InputDecoration(
            labelText: 'First due date (YYYY-MM-DD)',
          ),
        ),
      ],
      TextField(
        controller: _reason,
        enabled: _editable,
        maxLength: 500,
        decoration: const InputDecoration(labelText: 'Reason for demo account'),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: _confirmed,
        onChanged: _editable
            ? (value) => setState(() => _confirmed = value ?? false)
            : null,
        title: const Text(
          'I confirm this customer and these details are synthetic test data.',
        ),
      ),
      if (_message != null) Semantics(liveRegion: true, child: Text(_message!)),
      if (_busy)
        const LinearProgressIndicator(semanticsLabel: 'Creating demo account'),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy || _blocked ? null : _submit,
        child: Text(
          _attempt == null ? 'Create demo account' : 'Retry same request',
        ),
      ),
      TextButton(
        onPressed: _busy ? null : widget.onDone,
        child: const Text('Check customer'),
      ),
    ],
  );
}
