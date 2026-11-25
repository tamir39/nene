import 'package:flutter/material.dart';
import '../data/security_api.dart';
import '../data/session_owner.dart';
import 'customer_workspace.dart' show WorkspaceContent;
import 'nene_brand.dart';
import 'nene_components.dart';
import 'security_management_screen.dart';

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
  bool _manage = false;
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

  /// The current state in words, with an icon and tone that match it.
  Widget _status(bool setup) {
    if (_state == 'ready') {
      return const SecurityStatusCard(
        icon: Icons.verified_user_rounded,
        tone: SecurityTone.positive,
        title: 'Authenticator ready',
        body:
            'Each payment and transfer now asks for a code from this app. Save recovery codes in case you lose it.',
      );
    }
    if (_state == 'not_set_up') {
      return const SecurityStatusCard(
        icon: Icons.gpp_maybe_outlined,
        tone: SecurityTone.warning,
        title: 'Authenticator not set up',
      );
    }
    if (setup) {
      return const SecurityStatusCard(
        icon: Icons.hourglass_top_rounded,
        tone: SecurityTone.neutral,
        title: 'Setup in progress',
        body: 'Finish the steps below to link your authenticator.',
      );
    }
    if (_state == 'loading') {
      return const SecurityStatusCard(
        icon: Icons.shield_outlined,
        tone: SecurityTone.neutral,
        title: 'Checking your authenticator',
      );
    }
    return const SecurityStatusCard(
      icon: Icons.report_gmailerrorred_rounded,
      tone: SecurityTone.danger,
      title: 'Security needs attention',
      body:
          'Continue an existing security change below. An initial setup with a lost key still needs synthetic-demo assistance.',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_manage) {
      return SecurityManagementScreen(
        api: widget.api,
        onBack: () {
          setState(() => _manage = false);
          _load();
        },
      );
    }
    final setup = _state == 'pending' && _secret != null;
    return WorkspaceContent(
      children: [
        Text(
          'Transaction security',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'Set up an authenticator for future transaction confirmation. Setup does not approve a payment.',
          style: TextStyle(color: NeneColors.muted),
        ),
        const SizedBox(height: 16),
        SecurityProgressSlot(busy: _busy, label: 'Checking authenticator'),
        const SizedBox(height: 12),
        _status(setup),
        if (_message != null) ...[
          const SizedBox(height: 12),
          SecurityNotice(_message!, live: true),
        ],
        if (_state == 'not_set_up') ...[
          const SizedBox(height: 24),
          const SectionTitle('Before you start'),
          const SecurityPanel(
            children: [
              _Hint(
                Icons.schedule_rounded,
                'Sign in within the last five minutes before starting.',
              ),
              SizedBox(height: 16),
              _Hint(
                Icons.phonelink_lock_rounded,
                'In your authenticator app, choose a time-based code.',
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _start,
            child: const Text('Set up authenticator'),
          ),
        ] else if (setup) ...[
          const SizedBox(height: 24),
          const SectionTitle('Link your authenticator'),
          SecurityPanel(
            children: [
              const SecurityStep(
                number: 1,
                title: 'Open your authenticator app',
                body: 'Add an account named Nene with a time-based code.',
              ),
              const SizedBox(height: 22),
              SecurityStep(
                number: 2,
                title: 'Enter this setup key',
                body: 'Press and hold to copy it. Keep the key private.',
                child: _hidden
                    ? const SecurityHiddenNotice()
                    : SecurityKeyBlock(
                        secret: _secret!,
                        semanticsLabel: 'Private authenticator setup key',
                      ),
              ),
              const SizedBox(height: 22),
              SecurityStep(
                number: 3,
                title: 'Enter the 6-digit code',
                body: 'Type the code your authenticator shows for Nene.',
                child: _hidden
                    ? null
                    : TextField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        textAlign: TextAlign.center,
                        style: securityCodeStyle(),
                        decoration: securityCodeDecoration(
                          'Authenticator code',
                        ),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy || _hidden ? null : _verify,
            child: const Text('Verify setup'),
          ),
        ],
        if (['ready', 'restricted'].contains(_state)) ...[
          const SizedBox(height: 24),
          const SectionTitle('More options'),
          _ManageTile(
            onTap: _busy ? null : () => setState(() => _manage = true),
          ),
        ],
        const SizedBox(height: 16),
        Center(
          child: TextButton.icon(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Check status'),
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: NeneColors.pale,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: NeneColors.action, size: 20),
      ),
      const SizedBox(width: 14),
      Expanded(child: Text(text)),
    ],
  );
}

class _ManageTile extends StatelessWidget {
  const _ManageTile({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: NeneColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: onTap == null ? NeneColors.line : NeneColors.pale,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.manage_accounts_outlined,
                  color: onTap == null ? NeneColors.muted : NeneColors.action,
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Manage authenticator and recovery',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Replace your authenticator, use a recovery code or create new codes.',
                      style: TextStyle(color: NeneColors.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: NeneColors.muted),
            ],
          ),
        ),
      ),
    ),
  );
}
