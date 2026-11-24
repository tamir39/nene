import 'data/assistant_api.dart';
import 'data/branches_api.dart';
import 'data/savings_policy_api.dart';
import 'data/demo_accounts_api.dart';
import 'data/account_history_api.dart';
import 'data/security_api.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import 'data/banking_repository.dart';
import 'data/identity_repository.dart';
import 'data/reference_photo_source.dart';
import 'session_controller.dart';
import 'ui/customer_workspace.dart';
import 'ui/nene_brand.dart';

class NeneApp extends StatefulWidget {
  const NeneApp({
    super.key,
    this.controller,
    this.banking,
    this.identity,
    this.photos,
    this.security,
    this.savingsPolicy,
    this.demoAccounts,
    this.history,
    this.branches,
    this.assistant,
    this.onDispose,
  }) : assert((controller == null) == (banking == null));

  final SessionController? controller;
  final BankingRepository? banking;
  final IdentityRepository? identity;
  final ReferencePhotoSource? photos;
  final SecurityApi? security;
  final SavingsPolicyApi? savingsPolicy;
  final DemoAccountsApi? demoAccounts;
  final AccountHistoryApi? history;
  final BranchesApi? branches;
  final AssistantApi? assistant;
  final VoidCallback? onDispose;

  @override
  State<NeneApp> createState() => _NeneAppState();
}

class _NeneAppState extends State<NeneApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(widget.controller?.loadProfile());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        widget.controller?.status == SessionStatus.ready) {
      unawaited(widget.controller?.revalidateProfile());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?.dispose();
    widget.onDispose?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return MaterialApp(
      title: 'Nene',
      debugShowCheckedModeBanner: false,
      theme: neneTheme(),
      home: controller == null
          ? const _SetupUnavailable()
          : ListenableBuilder(
              listenable: controller,
              builder: (context, _) => switch (controller.status) {
                SessionStatus.signedOut => SignInScreen(controller: controller),
                SessionStatus.loading => const _SessionLoading(),
                SessionStatus.ready => CustomerWorkspace(
                  key: ValueKey(controller.generation),
                  session: controller,
                  repository: widget.banking!,
                  identity: widget.identity,
                  photos: widget.photos,
                  security: widget.security,
                  savingsPolicy: widget.savingsPolicy,
                  demoAccounts: widget.demoAccounts,
                  history: widget.history,
                  branches: widget.branches,
                  assistant: widget.assistant,
                ),
                SessionStatus.unavailable => _ProfileUnavailable(
                  controller: controller,
                ),
              },
            ),
    );
  }
}

class _SetupUnavailable extends StatelessWidget {
  const _SetupUnavailable();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: _Content(
      children: [
        const Center(child: NeneLogo()),
        const SizedBox(height: 40),
        const _StateIcon(Icons.cloud_off_rounded),
        const SizedBox(height: 20),
        Text(
          'Nene is unavailable',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 10),
        const Text(
          'This build is not ready to connect. Please contact the project team.',
          textAlign: TextAlign.center,
          style: TextStyle(color: NeneColors.muted),
        ),
      ],
    ),
  );
}

class _SessionLoading extends StatelessWidget {
  const _SessionLoading();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: _Content(
      children: [
        Center(child: NeneLogo(size: 52)),
        SizedBox(height: 44),
        Center(
          child: SizedBox.square(
            dimension: 36,
            child: CircularProgressIndicator(
              strokeWidth: 3.5,
              strokeCap: StrokeCap.round,
              backgroundColor: NeneColors.pale,
              semanticsLabel: 'Please wait',
            ),
          ),
        ),
        SizedBox(height: 18),
        Text(
          'Please wait…',
          textAlign: TextAlign.center,
          style: TextStyle(color: NeneColors.muted, fontSize: 15),
        ),
      ],
    ),
  );
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.controller});
  final SessionController controller;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _hidePassword = true;

  void _submit() {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    unawaited(widget.controller.signIn(_email.text, _password.text));
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: _Content(
      topAligned: true,
      children: [
        const _SignInHero(),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: NeneColors.line),
          ),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Welcome back',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Sign in with the details provided by your bank officer.',
                  style: TextStyle(color: NeneColors.muted),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.mail_outline_rounded),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.username],
                  autocorrect: false,
                  validator: (value) =>
                      value != null &&
                          RegExp(
                            r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                          ).hasMatch(value.trim())
                      ? null
                      : 'Enter a valid email address.',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _password,
                  obscureText: _hidePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      tooltip: _hidePassword
                          ? 'Show password'
                          : 'Hide password',
                      icon: Icon(
                        _hidePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _hidePassword = !_hidePassword),
                    ),
                  ),
                  validator: (value) => value != null && value.isNotEmpty
                      ? null
                      : 'Enter your password.',
                ),
                if (widget.controller.message != null) ...[
                  const SizedBox(height: 16),
                  _ErrorNotice(widget.controller.message!),
                ],
                const SizedBox(height: 24),
                FilledButton(onPressed: _submit, child: const Text('Sign in')),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              _StateIcon(Icons.support_agent_rounded, size: 40),
              SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Need access? A bank officer can help you get started.',
                  style: TextStyle(color: NeneColors.muted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        const Text.rich(
          TextSpan(
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.school_outlined,
                    size: 16,
                    color: NeneColors.muted,
                  ),
                ),
              ),
              TextSpan(text: 'Educational banking project · Demo only'),
            ],
          ),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: NeneColors.muted),
        ),
      ],
    ),
  );
}

/// Brand welcome panel: the logo, tagline and promise on a soft pocket tint.
class _SignInHero extends StatelessWidget {
  const _SignInHero();

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(28),
    child: ColoredBox(
      color: NeneColors.pale,
      child: Stack(
        children: [
          const Positioned(
            top: -56,
            right: -44,
            child: _Disc(size: 180, color: NeneColors.apricotSoft),
          ),
          Positioned(
            bottom: -96,
            right: -64,
            child: _Disc(
              size: 180,
              color: NeneColors.brand.withValues(alpha: .10),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const NeneLogo(size: 40),
                const SizedBox(height: 40),
                const Text(
                  'A little clarity, every day',
                  style: TextStyle(
                    color: NeneColors.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: .2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your money.\nWithin reach.',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    color: NeneColors.deep,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.8,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  width: 48,
                  height: 5,
                  decoration: BoxDecoration(
                    color: NeneColors.apricot,
                    borderRadius: BorderRadius.circular(3),
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

class _Disc extends StatelessWidget {
  const _Disc({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Tinted rounded-square icon used by the sign-in help line and state pages.
class _StateIcon extends StatelessWidget {
  const _StateIcon(this.icon, {this.size = 64});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: NeneColors.apricotSoft,
        borderRadius: BorderRadius.circular(size * .3),
      ),
      child: Icon(icon, color: NeneColors.deep, size: size * .5),
    ),
  );
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFBEDEC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: error.withValues(alpha: .22)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, color: error, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: error, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileUnavailable extends StatelessWidget {
  const _ProfileUnavailable({required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const NeneLogo(size: 30)),
    body: _Content(
      children: [
        const _StateIcon(Icons.person_off_outlined),
        const SizedBox(height: 20),
        Text(
          'Profile unavailable',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 10),
        Semantics(
          liveRegion: true,
          child: Text(
            controller.message!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: NeneColors.muted),
          ),
        ),
        const SizedBox(height: 28),
        FilledButton.icon(
          onPressed: controller.loadProfile,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: controller.signOut,
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
}

class _Content extends StatelessWidget {
  const _Content({required this.children, this.topAligned = false});
  final List<Widget> children;
  final bool topAligned;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Align(
      alignment: topAligned ? Alignment.topCenter : Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    ),
  );
}
