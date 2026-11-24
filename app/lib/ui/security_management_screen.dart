import 'dart:async';
import 'package:flutter/material.dart';
import '../data/security_api.dart';
import '../data/session_owner.dart';
import 'customer_workspace.dart' show WorkspaceContent;
import 'nene_brand.dart';
import 'nene_components.dart';

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
  Widget _input(String label, {double top = 18}) {
    final recovery = label.contains('Recovery');
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: TextField(
        controller: _code,
        enabled: !_busy,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        keyboardType: recovery ? TextInputType.text : TextInputType.number,
        textAlign: recovery ? TextAlign.start : TextAlign.center,
        style: securityCodeStyle(numeric: !recovery),
        decoration: securityCodeDecoration(
          label,
          numeric: !recovery,
          hint: '••••••',
        ),
      ),
    );
  }

  Widget _button(String label, VoidCallback action, {bool enabled = true}) =>
      Padding(
        padding: const EdgeInsets.only(top: 20),
        child: FilledButton(
          onPressed: _busy || _hidden || !enabled ? null : action,
          child: Text(label),
        ),
      );

  Widget _checkbox(String label, bool value, ValueChanged<bool?>? onChanged) =>
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: CheckboxListTile(
          value: value,
          onChanged: onChanged,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6),
          tileColor: NeneColors.pale,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: Text(
            label,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
          ),
        ),
      );

  /// One card per management step: what to do now, then its single action.
  Widget _step({
    required IconData icon,
    required String title,
    String? body,
    SecurityTone tone = SecurityTone.neutral,
    List<Widget> children = const [],
  }) {
    final colors = securityToneColors(context, tone);
    return SecurityPanel(
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: colors.foreground),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (body != null) ...[
          const SizedBox(height: 14),
          Text(body, style: const TextStyle(color: NeneColors.muted)),
        ],
        ...children,
      ],
    );
  }

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
    final locked = _busy || _hidden;
    return WorkspaceContent(
      children: [
        Text(
          'Authenticator and recovery',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'These actions change your security settings only. They never approve a payment. Start within five minutes of password sign-in.',
          style: TextStyle(color: NeneColors.muted),
        ),
        const SizedBox(height: 16),
        SecurityProgressSlot(busy: _busy, label: 'Updating security'),
        if (_message != null) ...[
          const SizedBox(height: 12),
          SecurityNotice(_message!, live: true),
        ],
        const SizedBox(height: 12),
        if (_loaded && m == null) ...[
          _RecoveryCodeCount(_remaining),
          const SizedBox(height: 12),
          const SecurityNotice(
            'Save backup codes before you lose access. If both your authenticator and codes are lost, recovery is blocked; an officer or password alone cannot reset it.',
            tone: SecurityTone.warning,
            title: 'Keep a backup',
          ),
          const SizedBox(height: 20),
          const SectionTitle('Recovery codes'),
          SecurityPanel(
            padding: EdgeInsets.zero,
            children: [
              _OptionTile(
                icon: Icons.key_rounded,
                title: 'Create / replace recovery codes',
                body: 'Get a fresh set of one-time backup codes.',
                onTap: locked ? null : () => _start('codes'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const SectionTitle('Authenticator'),
          SecurityPanel(
            padding: EdgeInsets.zero,
            children: [
              _OptionTile(
                icon: Icons.phonelink_setup_rounded,
                title: 'Replace authenticator',
                body: 'Switch to a new authenticator using your current one.',
                onTap: locked ? null : () => _start('replace'),
              ),
              const Divider(height: 1, indent: 74),
              _OptionTile(
                icon: Icons.lock_reset_rounded,
                title: 'Use a recovery code',
                body: 'Lost your authenticator? Use a saved recovery code.',
                onTap: locked ? null : () => _start('recover'),
              ),
            ],
          ),
        ],
        if (m != null) ...[
          const SecurityStatusCard(
            icon: Icons.lock_clock_outlined,
            tone: SecurityTone.warning,
            title: 'Security change in progress',
            body: 'Transaction confirmation is restricted.',
          ),
          const SizedBox(height: 16),
          if (needsResume && m['canResume'] == true)
            _step(
              icon: Icons.login_rounded,
              title: 'Prove access again',
              body:
                  'Sign in again with your password, then prove access to continue. If a recovery code was consumed before a reply was lost, use another unused code. A verified replacement requires its new authenticator code. Lost backup-code displays require deliberate regeneration.',
              children: [
                if (!_hidden) _input(proofLabel),
                _button('Resume with fresh proof', () => _proof('resume')),
              ],
            )
          else if (step == 'proof')
            _step(
              icon: Icons.password_rounded,
              title: 'Prove access',
              body: m['purpose'] == 'recover'
                  ? 'Use one previously saved recovery code to replace your lost authenticator.'
                  : 'Enter a fresh code from the authenticator you are replacing.',
              children: [
                if (!_hidden) _input(proofLabel),
                _button('Verify access', () => _proof('prove')),
              ],
            )
          else if (step == 'authorized')
            _step(
              icon: Icons.check_circle_outline_rounded,
              tone: SecurityTone.positive,
              title: 'Access confirmed',
              body:
                  'Keep the old authenticator until the replacement is verified.',
              children: [_button('Set up replacement', _enroll)],
            )
          else if (step == 'pending' && _secret != null)
            _step(
              icon: Icons.phonelink_setup_rounded,
              title: 'Add your new authenticator',
              children: [
                const SizedBox(height: 18),
                SecurityStep(
                  number: 1,
                  title: 'Add a new Nene account',
                  body:
                      'Add this private key to a new time-based Nene account in your authenticator.',
                  child: _hidden
                      ? const SecurityHiddenNotice()
                      : SecurityKeyBlock(
                          secret: _secret!,
                          semanticsLabel: 'Private replacement setup key',
                        ),
                ),
                const SizedBox(height: 22),
                SecurityStep(
                  number: 2,
                  title: 'Enter the 6-digit code',
                  body: 'Type the code your new authenticator shows for Nene.',
                  child: _hidden
                      ? null
                      : _input('New authenticator code', top: 6),
                ),
                _button('Verify replacement', () => _proof('verify')),
              ],
            )
          else if (step == 'verified')
            _step(
              icon: Icons.key_rounded,
              title: 'Issue new recovery codes',
              body:
                  'Wait for a new code from your active authenticator. This step retires the old authenticator when replacing and invalidates all previously unused recovery codes. New codes are displayed once.',
              children: [
                _checkbox(
                  'Replace the previous recovery-code set.',
                  _rotate,
                  _busy
                      ? null
                      : (value) => setState(() => _rotate = value ?? false),
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
              ],
            )
          else if (step == 'codes_shown' && _codes != null)
            _step(
              icon: Icons.key_rounded,
              title: 'Your new recovery codes',
              children: [
                const SizedBox(height: 16),
                const SecurityNotice(
                  'Save these codes privately outside Nene. Each works once for authenticator recovery only. They cannot be retrieved again.',
                  tone: SecurityTone.warning,
                  title: 'Save these privately now',
                ),
                const SizedBox(height: 16),
                if (_hidden)
                  const SecurityHiddenNotice()
                else
                  _RecoveryCodeGrid(_codes!),
                _checkbox(
                  'I saved my new recovery codes.',
                  _saved,
                  locked
                      ? null
                      : (value) => setState(() => _saved = value ?? false),
                ),
                _button(
                  'Finish and sign out everywhere',
                  _finish,
                  enabled: _saved,
                ),
              ],
            )
          else if (step == 'finishing')
            _step(
              icon: Icons.logout_rounded,
              title: 'Almost done',
              body:
                  'Final sign-out needs confirmation. Sign in again, then finish. This will revoke existing sessions.',
              children: [_button('Finish sign-out', _finish)],
            )
          else if (step == 'pending')
            _step(
              icon: Icons.key_off_rounded,
              tone: SecurityTone.danger,
              title: 'Setup key unavailable',
              body:
                  'The private setup key is no longer available. Cancel this unverified replacement, sign in again and start over.',
            ),
          if (['proof', 'authorized', 'pending', 'cancelling'].contains(step))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: TextButton.icon(
                  onPressed: _busy ? null : _cancel,
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Cancel change and sign out'),
                ),
              ),
            ),
          if (['proving', 'enrolling', 'issuing', 'cancelling'].contains(step))
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: SecurityNotice(
                'A provider request may have completed without confirmation. Security remains restricted. Check status; if it stays unresolved, ask the project team for synthetic-demo assistance. No reset or payment bypass is available.',
                tone: SecurityTone.warning,
              ),
            ),
        ],
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: _busy ? null : () => _run(_load),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Check status'),
            ),
            TextButton.icon(
              onPressed: _busy ? null : widget.onBack,
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Back to security status'),
            ),
          ],
        ),
      ],
    );
  }
}

class _RecoveryCodeCount extends StatelessWidget {
  const _RecoveryCodeCount(this.remaining);
  final int remaining;

  @override
  Widget build(BuildContext context) {
    final colors = securityToneColors(
      context,
      remaining == 0 ? SecurityTone.warning : SecurityTone.neutral,
    );
    return SecurityPanel(
      children: [
        Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(Icons.password_rounded, color: colors.foreground),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Text(
                'Unused recovery codes',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$remaining',
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: NeneColors.deep,
                fontFeatures: neneTabularFigures,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: onTap == null ? NeneColors.line : NeneColors.pale,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                icon,
                color: onTap == null ? NeneColors.muted : NeneColors.action,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: const TextStyle(
                      color: NeneColors.muted,
                      fontSize: 13,
                    ),
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
  );
}

/// Shown once: numbered cells that can be selected together, never read
/// aloud by assistive technology (matching the former private label).
class _RecoveryCodeGrid extends StatelessWidget {
  const _RecoveryCodeGrid(this.codes);
  final List<String> codes;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Private recovery codes',
    child: ExcludeSemantics(
      child: SelectionArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            const gap = 10.0;
            final columns = constraints.maxWidth >= 260 ? 2 : 1;
            final width =
                (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < codes.length; i++)
                  Container(
                    width: width,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: NeneColors.ivory,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: NeneColors.line),
                    ),
                    child: Row(
                      children: [
                        SelectionContainer.disabled(
                          child: Text(
                            '${i + 1}'.padLeft(2, '0'),
                            style: const TextStyle(
                              color: NeneColors.muted,
                              fontSize: 12,
                              fontFeatures: neneTabularFigures,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            codes[i],
                            style: securityMonoStyle.copyWith(fontSize: 15),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Visual building blocks shared by the two transaction-security screens
// (SecurityScreen imports this file). They carry no security behavior.
// ---------------------------------------------------------------------------

/// Tone of a security status, notice or step icon.
enum SecurityTone { neutral, positive, warning, danger }

/// Background tint and foreground color for a [SecurityTone].
({Color background, Color foreground}) securityToneColors(
  BuildContext context,
  SecurityTone tone,
) => switch (tone) {
  SecurityTone.neutral => (
    background: NeneColors.pale,
    foreground: NeneColors.action,
  ),
  SecurityTone.positive => (
    background: const Color(0xFFE3F3EA),
    foreground: NeneColors.positive,
  ),
  SecurityTone.warning => (
    background: NeneColors.apricotSoft,
    foreground: NeneColors.deep,
  ),
  SecurityTone.danger => (
    background: const Color(0xFFFBEDEC),
    foreground: Theme.of(context).colorScheme.error,
  ),
};

/// Monospace text for setup keys and recovery codes, falling back to the
/// brand font where the platform has no monospace family.
const securityMonoStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: [neneFontFamily],
  fontWeight: FontWeight.w600,
  color: NeneColors.ink,
  fontFeatures: neneTabularFigures,
);

/// Large, spaced digits for a one-time code entry field.
TextStyle securityCodeStyle({bool numeric = true}) => TextStyle(
  fontSize: numeric ? 24 : 18,
  fontWeight: FontWeight.w700,
  letterSpacing: numeric ? 8 : 1.5,
  color: NeneColors.ink,
  fontFeatures: neneTabularFigures,
);

/// Decoration for a one-time code entry field; hides the length counter.
/// Numeric codes keep their label above a centered placeholder.
InputDecoration securityCodeDecoration(
  String label, {
  bool numeric = true,
  String hint = '000000',
}) => InputDecoration(
  labelText: label,
  floatingLabelAlignment: numeric
      ? FloatingLabelAlignment.center
      : FloatingLabelAlignment.start,
  floatingLabelBehavior: numeric
      ? FloatingLabelBehavior.always
      : FloatingLabelBehavior.auto,
  hintText: numeric ? hint : null,
  hintStyle: securityCodeStyle().copyWith(
    color: NeneColors.muted.withValues(alpha: .35),
  ),
  counterText: '',
  filled: true,
  fillColor: Colors.white,
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: NeneColors.brand, width: 1.4),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: NeneColors.action, width: 2),
  ),
);

/// White rounded card with a hairline border, matching workspace cards.
class SecurityPanel extends StatelessWidget {
  const SecurityPanel({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.all(18),
  });
  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: NeneColors.line),
    ),
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

/// Status card: a tinted icon, the state in words and an optional note.
class SecurityStatusCard extends StatelessWidget {
  const SecurityStatusCard({
    super.key,
    required this.icon,
    required this.tone,
    required this.title,
    this.body,
  });
  final IconData icon;
  final SecurityTone tone;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final colors = securityToneColors(context, tone);
    return SecurityPanel(
      children: [
        Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: colors.foreground, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (body != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      body!,
                      style: const TextStyle(
                        color: NeneColors.muted,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Inline callout. [live] announces it to assistive technology on change.
class SecurityNotice extends StatelessWidget {
  const SecurityNotice(
    this.text, {
    super.key,
    this.tone = SecurityTone.danger,
    this.title,
    this.icon,
    this.live = false,
  });
  final String text;
  final SecurityTone tone;
  final String? title;
  final IconData? icon;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final colors = securityToneColors(context, tone);
    final danger = tone == SecurityTone.danger;
    return Semantics(
      liveRegion: live,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: tone == SecurityTone.warning
                ? NeneColors.apricot
                : colors.foreground.withValues(alpha: .2),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon ??
                  switch (tone) {
                    SecurityTone.danger => Icons.error_outline_rounded,
                    SecurityTone.warning => Icons.warning_amber_rounded,
                    SecurityTone.positive => Icons.check_circle_outline,
                    SecurityTone.neutral => Icons.info_outline_rounded,
                  },
              color: colors.foreground,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(
                      title!,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    text,
                    style: TextStyle(
                      color: danger ? colors.foreground : NeneColors.ink,
                      fontWeight: danger ? FontWeight.w500 : null,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reserves the progress bar's space so content does not jump while busy.
class SecurityProgressSlot extends StatelessWidget {
  const SecurityProgressSlot({
    super.key,
    required this.busy,
    required this.label,
  });
  final bool busy;
  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 4,
    child: busy
        ? ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 4,
              backgroundColor: NeneColors.pale,
              semanticsLabel: label,
            ),
          )
        : null,
  );
}

/// Numbered instruction with an optional control underneath.
class SecurityStep extends StatelessWidget {
  const SecurityStep({
    super.key,
    required this.number,
    required this.title,
    this.body,
    this.child,
  });
  final int number;
  final String title;
  final String? body;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: NeneColors.action,
          shape: BoxShape.circle,
        ),
        child: Text(
          '$number',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            fontFeatures: neneTabularFigures,
          ),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (body != null) ...[
              const SizedBox(height: 4),
              Text(
                body!,
                style: const TextStyle(color: NeneColors.muted, fontSize: 14),
              ),
            ],
            if (child != null) ...[const SizedBox(height: 12), child!],
          ],
        ),
      ),
    ],
  );
}

/// Private setup key in a selectable monospace block.
class SecurityKeyBlock extends StatelessWidget {
  const SecurityKeyBlock({
    super.key,
    required this.secret,
    required this.semanticsLabel,
  });
  final String secret;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
    decoration: BoxDecoration(
      color: NeneColors.pale,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: NeneColors.brand.withValues(alpha: .35)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ExcludeSemantics(
          child: Row(
            children: [
              Icon(Icons.key_rounded, size: 16, color: NeneColors.action),
              SizedBox(width: 6),
              Text(
                'SETUP KEY',
                style: TextStyle(
                  color: NeneColors.action,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          secret,
          semanticsLabel: semanticsLabel,
          style: securityMonoStyle.copyWith(
            fontSize: 17,
            letterSpacing: 1.6,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

/// Placeholder while private values are hidden for an inactive app.
class SecurityHiddenNotice extends StatelessWidget {
  const SecurityHiddenNotice({super.key});

  @override
  Widget build(BuildContext context) => const SecurityNotice(
    'Hidden until you return to Nene.',
    tone: SecurityTone.neutral,
    icon: Icons.visibility_off_outlined,
  );
}
