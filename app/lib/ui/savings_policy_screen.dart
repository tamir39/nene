import 'package:flutter/material.dart';
import '../data/savings_policy_api.dart';
import '../data/user_profile.dart';
import '../session_controller.dart';
import 'customer_workspace.dart' show WorkspaceContent;
import 'nene_brand.dart';

const _savedMessage =
    'Savings rate saved. Customer estimates use the new rate when refreshed.';

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
          _message = _savedMessage;
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
  Widget build(BuildContext context) {
    final policy = _policy;
    final saved = _message == _savedMessage;
    return WorkspaceContent(
      children: [
        Text('Savings rate', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text(
          'This annual rate applies to all savings estimates immediately. It does not credit interest or change balances.',
          style: TextStyle(color: NeneColors.muted),
        ),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: NeneColors.pale,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(
                        Icons.percent_rounded,
                        color: NeneColors.action,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Current annual rate',
                            style: TextStyle(
                              color: NeneColors.muted,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            policy != null
                                ? '${(policy.annualRateBps / 100).toStringAsFixed(2)}%'
                                : _busy
                                ? 'Loading…'
                                : 'Unavailable',
                            style: TextStyle(
                              fontSize: policy != null ? 28 : 18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.4,
                              color: policy != null
                                  ? NeneColors.ink
                                  : NeneColors.muted,
                              fontFeatures: neneTabularFigures,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (policy != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: NeneColors.ivory,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          'Version ${policy.revision}',
                          style: const TextStyle(
                            color: NeneColors.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            fontFeatures: neneTabularFigures,
                          ),
                        ),
                      ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Divider(),
                ),
                TextField(
                  controller: _rate,
                  enabled: !_busy && policy != null,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(fontFeatures: neneTabularFigures),
                  decoration: const InputDecoration(
                    labelText: 'New annual rate (%)',
                    helperText: '0–20%, up to two decimals',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _reason,
                  enabled: !_busy && policy != null,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Reason for rate change',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy || policy == null ? null : _save,
          child: const Text('Save savings rate'),
        ),
        // Feedback sits below the action so the form never shifts under it.
        if (_busy) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(
            semanticsLabel: 'Loading savings rate',
            borderRadius: BorderRadius.all(Radius.circular(99)),
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: saved ? const Color(0xFFE3F3EA) : NeneColors.apricotSoft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    saved
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    size: 20,
                    color: saved
                        ? NeneColors.positive
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _message!,
                      style: const TextStyle(fontSize: 13.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Reload current rate'),
        ),
      ],
    );
  }
}
