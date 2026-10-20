import 'dart:async';

import 'package:flutter/material.dart';

import '../customer_flow_controller.dart';
import '../data/banking_repository.dart';
import '../data/user_profile.dart';
import '../session_controller.dart';
import 'nene_brand.dart';

enum _Page { home, contact, create, search, detail, editCustomer }

/// All protected pages live below the session branch, so signing out/expiring
/// disposes the entire workspace instead of leaving protected Navigator routes.
class CustomerWorkspace extends StatefulWidget {
  const CustomerWorkspace({
    super.key,
    required this.session,
    required this.repository,
  });

  final SessionController session;
  final BankingRepository repository;

  @override
  State<CustomerWorkspace> createState() => _CustomerWorkspaceState();
}

class _CustomerWorkspaceState extends State<CustomerWorkspace> {
  late final CustomerFlowController _flow;
  _Page _page = _Page.home;
  String? _customerId;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _flow = CustomerFlowController(
      session: widget.session,
      repository: widget.repository,
    );
    if (widget.session.profile!.role == AppRole.customer) {
      unawaited(_flow.loadAccounts());
    }
  }

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  void _go(_Page page, {String? notice}) {
    FocusScope.of(context).unfocus();
    setState(() {
      _page = page;
      _notice = notice;
    });
  }

  void _openCustomer(String id) {
    _customerId = id;
    _go(_Page.detail);
    unawaited(_flow.loadCustomer(id));
  }

  void _back() {
    if (_page == _Page.editCustomer) {
      _go(_Page.detail);
    } else if (_page == _Page.detail) {
      _go(_Page.search);
    } else {
      _go(_Page.home);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _flow,
    builder: (context, _) {
      final profile = widget.session.profile;
      if (profile == null) return const SizedBox.shrink();
      final busy =
          _flow.creating || _flow.savingContact || _flow.savingCustomer;
      final canBack =
          _page != _Page.home &&
          !busy &&
          !(_page == _Page.create && _flow.hasCreationAttempt);
      return PopScope(
        canPop: _page == _Page.home,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && canBack) _back();
        },
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: canBack
                ? IconButton(
                    tooltip: 'Back',
                    onPressed: _back,
                    icon: const Icon(Icons.arrow_back),
                  )
                : null,
            title: const NeneLogo(size: 30),
            actions: [
              IconButton(
                tooltip: 'Sign out',
                onPressed: widget.session.signOut,
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          body: switch (_page) {
            _Page.home => _home(profile),
            _Page.contact => ContactForm(
              key: const ValueKey('own-contact'),
              profile: profile,
              flow: _flow,
              onSaved: () => _go(_Page.home, notice: 'Contact details saved.'),
            ),
            _Page.create => CreateCustomerForm(
              flow: _flow,
              onCreated: (customer) {
                _customerId = customer.id;
                _go(
                  _Page.detail,
                  notice:
                      'Customer created. Share the sign-in email and the initial '
                      'password you entered through a private channel. The password '
                      'is no longer shown or retained by this form.',
                );
              },
            ),
            _Page.search => _SearchCustomers(
              flow: _flow,
              onOpen: _openCustomer,
            ),
            _Page.detail => _detail(),
            _Page.editCustomer => _OfficerEditForm(
              key: ValueKey(_flow.selectedCustomer!.id),
              customer: _flow.selectedCustomer!,
              flow: _flow,
              onSaved: () =>
                  _go(_Page.detail, notice: 'Requested changes saved.'),
            ),
          },
        ),
      );
    },
  );

  Widget _home(UserProfile profile) {
    final officer = profile.role == AppRole.officer;
    return WorkspaceContent(
      children: [
        Text(
          officer ? 'Officer workspace' : 'My accounts',
          style: const TextStyle(color: NeneColors.muted),
        ),
        const SizedBox(height: 12),
        Text(
          profile.displayName,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Chip(
            avatar: Icon(
              officer ? Icons.badge_outlined : Icons.person_outline,
              size: 20,
            ),
            label: Text(officer ? 'Bank officer' : 'Customer'),
            backgroundColor: const Color(0xFFF9E7D8),
            side: BorderSide.none,
          ),
        ),
        if (_notice != null) ...[
          const SizedBox(height: 16),
          _Message(_notice!),
        ],
        const SizedBox(height: 24),
        if (officer) ...[
          const Text(
            'Help a customer get started',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Create a customer and their first checking account, or find a '
            'customer to handle a requested profile change.',
            style: TextStyle(color: NeneColors.muted),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => _go(_Page.create),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Create customer'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _go(_Page.search),
            icon: const Icon(Icons.search),
            label: const Text('Find a customer'),
          ),
          const SizedBox(height: 28),
        ] else ...[
          if (_flow.loadingAccounts) const _Loading('Loading your accounts'),
          if (_flow.accountsError != null) ...[
            _Message(_flow.accountsError!, error: true),
            TextButton(
              onPressed: _flow.loadAccounts,
              child: const Text('Retry accounts'),
            ),
          ] else if (_flow.accounts != null) ...[
            if (_flow.accounts!.isEmpty)
              const _Message(
                'No accounts are linked yet. Your bank officer can help.',
              )
            else
              for (final account in _flow.accounts!) _AccountCard(account),
          ],
          const SizedBox(height: 20),
          const _Message(
            'Identity verification is not completed in this demo. '
            'Deposits, withdrawals, transfers and payments are not available.',
          ),
          const SizedBox(height: 28),
        ],
        Text('My profile', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        _Info('Email', profile.email ?? 'Not provided'),
        if (!officer) ...[
          _Info('Phone', profile.phone ?? 'Not provided'),
          _Info('Address', profile.address ?? 'Not provided'),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () {
              _flow.clearContactError();
              _go(_Page.contact);
            },
            child: const Text('Edit contact details'),
          ),
        ],
      ],
    );
  }

  Widget _detail() {
    final customer = _flow.selectedCustomer;
    return WorkspaceContent(
      children: [
        const _Heading('Customer details'),
        if (_notice != null) ...[
          _Message(_notice!),
          const SizedBox(height: 20),
        ],
        if (_flow.loadingCustomer) const _Loading('Loading customer'),
        if (_flow.customerError != null) ...[
          _Message(_flow.customerError!, error: true),
          TextButton(
            onPressed: () => _flow.loadCustomer(_customerId!),
            child: const Text('Retry customer'),
          ),
        ],
        if (customer != null) ...[
          _Info('Name', customer.displayName),
          _Info('Sign-in email', customer.email ?? 'Not provided'),
          _Info('Phone', customer.phone ?? 'Not provided'),
          _Info('Address', customer.address ?? 'Not provided'),
          const SizedBox(height: 12),
          const _Message(
            'Identity is unverified. Creating a customer does not complete eKYC '
            'or enable money movements.',
          ),
          const SizedBox(height: 20),
          if (customer.accounts.isEmpty)
            const Text('No linked accounts.')
          else
            for (final account in customer.accounts) _AccountCard(account),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              _flow.clearCustomerSaveError();
              _go(_Page.editCustomer);
            },
            child: const Text('Make a requested change'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => _go(_Page.search),
            child: const Text('Find another customer'),
          ),
        ],
      ],
    );
  }
}

class ContactForm extends StatefulWidget {
  const ContactForm({
    super.key,
    required this.profile,
    required this.flow,
    required this.onSaved,
  });
  final UserProfile profile;
  final CustomerFlowController flow;
  final VoidCallback onSaved;

  @override
  State<ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends State<ContactForm> {
  final _form = GlobalKey<FormState>();
  late final _phone = TextEditingController(text: widget.profile.phone);
  late final _address = TextEditingController(text: widget.profile.address);

  Future<void> _save() async {
    if (!_form.currentState!.validate() || widget.flow.savingContact) return;
    FocusScope.of(context).unfocus();
    final saved = await widget.flow.saveContact(
      _nullable(_phone.text),
      _nullable(_address.text),
    );
    if (mounted && saved) widget.onSaved();
  }

  @override
  void dispose() {
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      const _Heading('Edit contact details'),
      const Text(
        'You can update your phone and address. Leave a field blank to remove it. '
        'Contact your officer for a name or sign-in email correction.',
      ),
      const SizedBox(height: 24),
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ContactFields(
              phone: _phone,
              address: _address,
              enabled: !widget.flow.savingContact,
            ),
            if (widget.flow.contactError != null)
              _Message(widget.flow.contactError!, error: true),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: widget.flow.savingContact ? null : _save,
              child: Text(
                widget.flow.savingContact ? 'Saving…' : 'Save contact details',
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class CreateCustomerForm extends StatefulWidget {
  const CreateCustomerForm({
    super.key,
    required this.flow,
    required this.onCreated,
  });
  final CustomerFlowController flow;
  final ValueChanged<CustomerDetail> onCreated;

  @override
  State<CreateCustomerForm> createState() => _CreateCustomerFormState();
}

class _CreateCustomerFormState extends State<CreateCustomerForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _password = TextEditingController();
  CustomerDraft? _review;
  bool _hidePassword = true;

  void _prepareReview() {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _review = CustomerDraft(
        email: _email.text.trim().toLowerCase(),
        displayName: _name.text.trim(),
        phone: _nullable(_phone.text),
        address: _nullable(_address.text),
        initialPassword: _password.text,
      );
    });
  }

  Future<void> _create() async {
    if (widget.flow.creating) return;
    final pendingDraft = _review;
    _password.clear();
    final result = await widget.flow.createCustomer(pendingDraft);
    if (!mounted) return;
    if (result != null) {
      _review = null;
      _name.clear();
      _email.clear();
      _phone.clear();
      _address.clear();
      widget.onCreated(result);
    } else if (widget.flow.hasCreationAttempt) {
      // The controller now owns the only body needed for an exact retry.
      setState(() => _review = null);
    }
  }

  void _edit() {
    widget.flow.correctCreation();
    setState(() => _review = null);
  }

  @override
  void dispose() {
    _review = null;
    for (final field in [_name, _email, _phone, _address, _password]) {
      field.clear();
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reviewing = _review != null || widget.flow.hasCreationAttempt;
    return WorkspaceContent(
      key: ValueKey(reviewing ? 'creation-review' : 'creation-fields'),
      children: [
        _Heading(reviewing ? 'Review customer' : 'Create customer'),
        const _Message(
          'This demo creates one VND checking account with a zero balance. '
          'Identity remains unverified and money movements stay unavailable.',
        ),
        const SizedBox(height: 24),
        if (reviewing) ...[
          _Info('Name', _name.text.trim()),
          _Info('Sign-in email', _email.text.trim().toLowerCase()),
          _Info('Phone', _nullable(_phone.text) ?? 'Not provided'),
          _Info('Address', _nullable(_address.text) ?? 'Not provided'),
          const _Info('Initial password', 'Set · hidden'),
          const SizedBox(height: 12),
          const Text(
            'Use synthetic details for this project demo. Share the access '
            'details privately with the customer. There is no invitation email '
            'or password-reset flow in this slice.',
          ),
          if (widget.flow.creationError != null) ...[
            const SizedBox(height: 20),
            _Message(widget.flow.creationError!, error: true),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: widget.flow.creating ? null : _create,
            child: Text(
              widget.flow.creating
                  ? 'Creating customer…'
                  : widget.flow.hasCreationAttempt
                  ? 'Retry same request'
                  : 'Confirm and create',
            ),
          ),
          if (!widget.flow.creating &&
              (!widget.flow.hasCreationAttempt ||
                  widget.flow.canCorrectCreation))
            TextButton(onPressed: _edit, child: const Text('Edit details')),
          if (widget.flow.hasCreationAttempt) ...[
            const SizedBox(height: 12),
            const Text(
              'Do not close or sign out until the outcome is confirmed. Pending '
              'request details are kept only in memory. If the session ends, '
              'find the customer by email before attempting another creation.',
              style: TextStyle(color: NeneColors.muted),
            ),
          ],
        ] else
          Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _NameField(controller: _name),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Sign-in email'),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 254,
                  validator: (value) =>
                      value != null &&
                          RegExp(
                            r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                          ).hasMatch(value.trim()) &&
                          !_hasControl(value)
                      ? null
                      : 'Enter a valid email address.',
                ),
                const SizedBox(height: 20),
                _ContactFields(phone: _phone, address: _address),
                TextFormField(
                  controller: _password,
                  obscureText: _hidePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  maxLength: 128,
                  decoration: InputDecoration(
                    labelText: 'Initial password',
                    helperText: 'Use 12–128 characters.',
                    suffixIcon: IconButton(
                      tooltip: _hidePassword
                          ? 'Show password'
                          : 'Hide password',
                      onPressed: () =>
                          setState(() => _hidePassword = !_hidePassword),
                      icon: Icon(
                        _hidePassword ? Icons.visibility : Icons.visibility_off,
                      ),
                    ),
                  ),
                  validator: (value) =>
                      value != null &&
                          value.length >= 12 &&
                          value.length <= 128 &&
                          !_hasControl(value)
                      ? null
                      : 'Enter 12–128 characters without control characters.',
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _prepareReview,
                  child: const Text('Review customer'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SearchCustomers extends StatefulWidget {
  const _SearchCustomers({required this.flow, required this.onOpen});
  final CustomerFlowController flow;
  final ValueChanged<String> onOpen;

  @override
  State<_SearchCustomers> createState() => _SearchCustomersState();
}

class _SearchCustomersState extends State<_SearchCustomers> {
  late final _query = TextEditingController(text: widget.flow.searchQuery);

  void _search() {
    FocusScope.of(context).unfocus();
    unawaited(widget.flow.search(_query.text));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      const _Heading('Find a customer'),
      TextField(
        controller: _query,
        decoration: const InputDecoration(labelText: 'Name or email'),
        textInputAction: TextInputAction.search,
        maxLength: 100,
        onSubmitted: (_) => _search(),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: widget.flow.searching ? null : _search,
        child: const Text('Search customers'),
      ),
      const SizedBox(height: 24),
      if (widget.flow.searching)
        const _Loading('Searching customers')
      else if (widget.flow.searchError != null)
        _Message(widget.flow.searchError!, error: true)
      else if (widget.flow.customers == null)
        const Text('Enter a name or email to find a customer.')
      else if (widget.flow.customers!.isEmpty)
        const Text('No customers found. Check the name or email and try again.')
      else ...[
        const Text(
          'Showing up to 20 matches. Use a more specific name or email if needed.',
          style: TextStyle(color: NeneColors.muted),
        ),
        const SizedBox(height: 12),
        for (final customer in widget.flow.customers!)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    customer.displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(customer.email ?? 'No email available'),
                  TextButton(
                    onPressed: () => widget.onOpen(customer.id),
                    child: const Text('View customer'),
                  ),
                ],
              ),
            ),
          ),
      ],
    ],
  );
}

class _OfficerEditForm extends StatefulWidget {
  const _OfficerEditForm({
    super.key,
    required this.customer,
    required this.flow,
    required this.onSaved,
  });
  final CustomerDetail customer;
  final CustomerFlowController flow;
  final VoidCallback onSaved;

  @override
  State<_OfficerEditForm> createState() => _OfficerEditFormState();
}

class _OfficerEditFormState extends State<_OfficerEditForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.customer.displayName);
  late final _phone = TextEditingController(text: widget.customer.phone);
  late final _address = TextEditingController(text: widget.customer.address);
  final _reason = TextEditingController();

  Future<void> _save() async {
    if (!_form.currentState!.validate() || widget.flow.savingCustomer) return;
    FocusScope.of(context).unfocus();
    final saved = await widget.flow.saveCustomer(
      displayName: _name.text.trim(),
      phone: _nullable(_phone.text),
      address: _nullable(_address.text),
      requestReason: _reason.text.trim(),
    );
    if (mounted && saved) widget.onSaved();
  }

  @override
  void dispose() {
    for (final field in [_name, _phone, _address, _reason]) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      const _Heading('Requested profile change'),
      const Text(
        'Make only the changes the customer requested. Sign-in email changes '
        'are not supported in this demo.',
      ),
      const SizedBox(height: 20),
      _Info('Sign-in email', widget.customer.email ?? 'Not provided'),
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _NameField(controller: _name, enabled: !widget.flow.savingCustomer),
            const SizedBox(height: 20),
            _ContactFields(
              phone: _phone,
              address: _address,
              enabled: !widget.flow.savingCustomer,
            ),
            TextFormField(
              controller: _reason,
              enabled: !widget.flow.savingCustomer,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Customer request / reason',
                helperText: 'Describe the requested change (5–500 characters).',
                helperMaxLines: 4,
              ),
              validator: (value) =>
                  value != null &&
                      value.trim().length >= 5 &&
                      value.trim().length <= 500 &&
                      !_hasControl(value)
                  ? null
                  : 'Enter a reason of 5–500 characters.',
            ),
            if (widget.flow.customerSaveError != null)
              _Message(widget.flow.customerSaveError!, error: true),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: widget.flow.savingCustomer ? null : _save,
              child: Text(
                widget.flow.savingCustomer
                    ? 'Saving…'
                    : 'Save requested changes',
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _ContactFields extends StatelessWidget {
  const _ContactFields({
    required this.phone,
    required this.address,
    this.enabled = true,
  });
  final TextEditingController phone;
  final TextEditingController address;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextFormField(
        controller: phone,
        enabled: enabled,
        decoration: const InputDecoration(labelText: 'Phone (optional)'),
        keyboardType: TextInputType.phone,
        textInputAction: TextInputAction.next,
        maxLength: 32,
        validator: (value) {
          final text = value?.trim() ?? '';
          if (text.isEmpty) return null;
          return text.length >= 5 &&
                  text.length <= 32 &&
                  RegExp(r'[0-9]').hasMatch(text) &&
                  RegExp(r'^\+?[0-9 ()-]+$').hasMatch(text)
              ? null
              : 'Use 5–32 characters: digits, spaces, +, (, ) or -.';
        },
      ),
      const SizedBox(height: 20),
      TextFormField(
        controller: address,
        enabled: enabled,
        decoration: const InputDecoration(labelText: 'Address (optional)'),
        textInputAction: TextInputAction.next,
        maxLength: 300,
        validator: (value) =>
            value == null || (value.trim().length <= 300 && !_hasControl(value))
            ? null
            : 'Use up to 300 characters without control characters.',
      ),
      const SizedBox(height: 20),
    ],
  );
}

class _NameField extends StatelessWidget {
  const _NameField({required this.controller, this.enabled = true});
  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    enabled: enabled,
    decoration: const InputDecoration(labelText: 'Full name'),
    textInputAction: TextInputAction.next,
    maxLength: 120,
    validator: (value) =>
        value != null &&
            value.trim().isNotEmpty &&
            value.trim().length <= 120 &&
            !_hasControl(value)
        ? null
        : 'Enter a name of 1–120 characters.',
  );
}

class _AccountCard extends StatelessWidget {
  const _AccountCard(this.account);
  final BankAccount account;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            account.typeLabel,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Text(
            account.balanceLabel,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          const Text(
            'Account number',
            style: TextStyle(color: NeneColors.muted),
          ),
          const SizedBox(height: 4),
          SelectableText(account.accountNumber),
          const SizedBox(height: 12),
          Text('Account status: ${account.status}'),
        ],
      ),
    ),
  );
}

class WorkspaceContent extends StatelessWidget {
  const WorkspaceContent({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Align(
      alignment: Alignment.topCenter,
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

class _Info extends StatelessWidget {
  const _Info(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: const TextStyle(color: NeneColors.muted)),
        const SizedBox(height: 5),
        SelectableText(value),
      ],
    ),
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Text(text, style: Theme.of(context).textTheme.headlineSmall),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: NeneColors.pale,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: error ? Theme.of(context).colorScheme.error : NeneColors.ink,
        ),
      ),
    ),
  );
}

class _Loading extends StatelessWidget {
  const _Loading(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      children: [
        CircularProgressIndicator(semanticsLabel: label),
        const SizedBox(height: 16),
        Text(label),
      ],
    ),
  );
}

String? _nullable(String text) => text.trim().isEmpty ? null : text.trim();
bool _hasControl(String text) => RegExp(r'[\x00-\x1f\x7f]').hasMatch(text);
