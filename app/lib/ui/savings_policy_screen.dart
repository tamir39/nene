import 'package:flutter/material.dart';
import '../data/savings_policy_api.dart';
import '../data/user_profile.dart';
import '../session_controller.dart';
import 'customer_workspace.dart' show WorkspaceContent;

class SavingsPolicyScreen extends StatefulWidget {
  const SavingsPolicyScreen({
    super.key,
    required this.session,
    required this.api,
  });
  final SessionController session;
  final SavingsPolicyApi api;
  @override
  State<SavingsPolicyScreen> createState() => _SavingsPolicyScreenState();
}

class _SavingsPolicyScreenState extends State<SavingsPolicyScreen> {
  final _rate = TextEditingController(), _reason = TextEditingController();
  SavingsPolicy? _policy;
  bool _busy = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rate.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final value = await widget.session.authorized(
        widget.api.read,
        role: AppRole.officer,
      );
      if (mounted) {
        setState(() {
          _policy = value;
          _rate.text = (value.annualRateBps / 100).toStringAsFixed(2);
          _message = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Unable to load the savings rate. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final raw = _rate.text.trim();
    if (!RegExp(r'^\d{1,2}(\.\d{1,2})?$').hasMatch(raw) ||
        double.parse(raw) > 20 ||
        _reason.text.trim().length < 5 ||
        _reason.text.trim().length > 500) {
      setState(
        () => _message =
            'Enter a rate from 0 to 20% with at most two decimals and a reason of 5–500 characters.',
      );
      return;
    }
    final parts = raw.split('.');
    final bps =
        int.parse(parts[0]) * 100 +
        int.parse(parts.length == 2 ? parts[1].padRight(2, '0') : '0');
    setState(() => _busy = true);
    try {
      final value = await widget.session.authorized(
        (token) =>
            widget.api.save(token, bps, _policy!.revision, _reason.text.trim()),
        role: AppRole.officer,
      );
      if (mounted) {
        setState(() {
          _policy = value;
          _reason.clear();
          _message =
              'Savings rate saved. Customer estimates use the new rate when refreshed.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _policy = null;
          _message =
              'The change could not be confirmed. Reload the current rate before trying again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      Text('Savings rate', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 16),
      const Text(
        'This annual rate applies to all savings estimates immediately. It does not credit interest or change balances.',
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_message != null) Text(_message!),
      TextField(
        controller: _rate,
        enabled: !_busy && _policy != null,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Annual rate (%)'),
      ),
      TextField(
        controller: _reason,
        enabled: !_busy && _policy != null,
        maxLength: 500,
        decoration: const InputDecoration(labelText: 'Reason for rate change'),
      ),
      FilledButton(
        onPressed: _busy || _policy == null ? null : _save,
        child: const Text('Save savings rate'),
      ),
      TextButton(
        onPressed: _busy ? null : _load,
        child: const Text('Reload current rate'),
      ),
    ],
  );
}
