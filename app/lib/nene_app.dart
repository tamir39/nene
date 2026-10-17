import 'dart:async';

import 'package:flutter/material.dart';

import 'data/user_profile.dart';
import 'session_controller.dart';

class NeneApp extends StatefulWidget {
  const NeneApp({super.key, this.controller, this.onDispose});

  final SessionController? controller;
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
      unawaited(widget.controller?.loadProfile());
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF164E63)),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: controller == null
          ? const _SetupUnavailable()
          : ListenableBuilder(
              listenable: controller,
              builder: (context, _) => switch (controller.status) {
                SessionStatus.signedOut => SignInScreen(controller: controller),
                SessionStatus.loading => const Scaffold(
                  body: Center(
                    child: CircularProgressIndicator(
                      semanticsLabel: 'Please wait',
                    ),
                  ),
                ),
                SessionStatus.ready => _ProfileScreen(
                  profile: controller.profile!,
                  onSignOut: controller.signOut,
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
        Icon(Icons.account_balance_outlined, size: 48),
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
      children: [
        const Icon(Icons.account_balance_outlined, size: 48),
        const SizedBox(height: 24),
        Text(
          'Welcome to Nene',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text('Sign in with your existing account.'),
        const SizedBox(height: 32),
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
                  child: Text(widget.controller.message!),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(onPressed: _submit, child: const Text('Sign in')),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text('Need an account? Please contact your bank officer.'),
      ],
    ),
  );
}

class _ProfileScreen extends StatelessWidget {
  const _ProfileScreen({required this.profile, required this.onSignOut});
  final UserProfile profile;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final isOfficer = profile.role == AppRole.officer;
    return Scaffold(
      appBar: AppBar(
        title: Text(isOfficer ? 'Officer workspace' : 'My profile'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: onSignOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: _Content(
        children: [
          Icon(
            isOfficer ? Icons.badge_outlined : Icons.person_outline,
            size: 48,
          ),
          const SizedBox(height: 24),
          Text(
            profile.displayName,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(isOfficer ? 'Bank officer' : 'Customer'),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Email', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Text(profile.email ?? 'No email available'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Banking services are not available in this preview.'),
        ],
      ),
    );
  }
}

class _ProfileUnavailable extends StatelessWidget {
  const _ProfileUnavailable({required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Nene')),
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
  const _Content({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
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
