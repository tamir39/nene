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
    this.onDispose,
  }) : assert((controller == null) == (banking == null));

  final SessionController? controller;
  final BankingRepository? banking;
  final IdentityRepository? identity;
  final ReferencePhotoSource? photos;
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
                SessionStatus.loading => const Scaffold(
                  body: _Content(
                    children: [
                      NeneLogo(),
                      SizedBox(height: 32),
                      Center(
                        child: CircularProgressIndicator(
                          semanticsLabel: 'Please wait',
                        ),
                      ),
                      SizedBox(height: 20),
                      Text('Please wait…', textAlign: TextAlign.center),
                    ],
                  ),
                ),
                SessionStatus.ready => CustomerWorkspace(
                  key: ValueKey(controller.generation),
                  session: controller,
                  repository: widget.banking!,
                  identity: widget.identity,
                  photos: widget.photos,
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
  Widget build(BuildContext context) => const Scaffold(
    body: _Content(
      children: [
        NeneLogo(),
        SizedBox(height: 24),
        Text('Nene is unavailable', style: TextStyle(fontSize: 24)),
        SizedBox(height: 12),
        Text(
          'This build is not ready to connect. Please contact the project team.',
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
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: NeneColors.pale,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const NeneLogo(),
              const SizedBox(height: 28),
              const Text(
                'A little clarity, every day',
                style: TextStyle(color: NeneColors.muted, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                'Your money.\nWithin reach.',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  color: NeneColors.action,
                  fontWeight: FontWeight.w600,
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
        const SizedBox(height: 28),
        Text('Welcome back', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Sign in with the details provided by your bank officer.',
          style: TextStyle(color: NeneColors.muted),
        ),
        const SizedBox(height: 24),
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email'),
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
              const SizedBox(height: 20),
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
                  suffixIcon: IconButton(
                    tooltip: _hidePassword ? 'Show password' : 'Hide password',
                    icon: Icon(
                      _hidePassword ? Icons.visibility : Icons.visibility_off,
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
                Semantics(
                  liveRegion: true,
                  child: Text(
                    widget.controller.message!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(onPressed: _submit, child: const Text('Sign in')),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Need access? A bank officer can help you get started.',
          style: TextStyle(color: NeneColors.muted),
        ),
        const SizedBox(height: 24),
        const Text(
          'Educational banking project · Demo only',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: NeneColors.muted),
        ),
      ],
    ),
  );
}

class _ProfileUnavailable extends StatelessWidget {
  const _ProfileUnavailable({required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const NeneLogo(size: 30)),
    body: _Content(
      children: [
        const Icon(Icons.info_outline, size: 48),
        const SizedBox(height: 24),
        Semantics(liveRegion: true, child: Text(controller.message!)),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: controller.loadProfile,
          child: const Text('Try again'),
        ),
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
