import 'assistant_screen.dart';
import 'payments_screen.dart';
import '../data/payments_api.dart';
import '../assistant_controller.dart';
import '../data/assistant_api.dart';
import 'branch_map_screen.dart';
import '../data/branches_api.dart';
import 'savings_policy_screen.dart';
import 'confirmation_screen.dart';
import '../data/confirmation_api.dart';
import 'demo_account_screen.dart';
import 'account_history_screen.dart';
import '../data/account_history_api.dart';
import '../data/demo_accounts_api.dart';
import '../data/savings_policy_api.dart';
import 'security_screen.dart';
import '../data/security_api.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../customer_flow_controller.dart';
import '../data/banking_repository.dart';
import '../data/identity_repository.dart';
import '../data/reference_photo_source.dart';
import '../data/user_profile.dart';
import '../session_controller.dart';
import 'nene_brand.dart';
import 'nene_components.dart';
import 'identity_reference_screen.dart';

enum _Page {
  home,
  branches,
  assistant,
  assistantAccounts,
  contact,
  create,
  search,
  detail,
  editCustomer,
  identity,
  security,
  savingsPolicy,
  demoAccount,
  history,
  confirmation,
  payments,
  profile,
}

/// All protected pages live below the session branch, so signing out/expiring
/// disposes the entire workspace instead of leaving protected Navigator routes.
class CustomerWorkspace extends StatefulWidget {
  const CustomerWorkspace({
    super.key,
    required this.session,
    required this.repository,
    this.identity,
    this.photos,
    this.security,
    this.savingsPolicy,
    this.demoAccounts,
    this.history,
    this.branches,
    this.assistant,
  });

  final SessionController session;
  final BankingRepository repository;
  final IdentityRepository? identity;
  final ReferencePhotoSource? photos;
  final SecurityApi? security;
  final SavingsPolicyApi? savingsPolicy;
  final DemoAccountsApi? demoAccounts;
  final AccountHistoryApi? history;
  final BranchesApi? branches;
  final AssistantApi? assistant;

  @override
  State<CustomerWorkspace> createState() => _CustomerWorkspaceState();
}

class _CustomerWorkspaceState extends State<CustomerWorkspace> {
  late final CustomerFlowController _flow;
  _Page _page = _Page.home;
  String? _customerId;
  String? _notice;
  BankAccount? _historyAccount;
  BankAccount? _confirmationAccount;
  bool _sendDemoMoney = false;
  bool _interbank = false;
  CashOperation? _cashOperation;
  AssistantController? _assistant;
  AssistantAction? _assistantAction;
  bool _assistantDestination = false;
  String? _historyMonth;
  String? _paymentService;
  bool _moviePayments = false;
  bool _hideBalance = false;
  _Page _tabOrigin = _Page.home;

  @override
  void initState() {
    super.initState();
    _flow = CustomerFlowController(
      session: widget.session,
      repository: widget.repository,
    );
    if (widget.session.profile!.role == AppRole.customer) {
      if (widget.assistant != null) {
        _assistant = AssistantController(
          session: widget.session,
          api: widget.assistant!,
        );
      }
      unawaited(_flow.loadAccounts());
    }
  }

  @override
  void dispose() {
    _assistant?.dispose();
    _flow.dispose();
    super.dispose();
  }

  static const _tabPages = {
    _Page.home,
    _Page.assistant,
    _Page.branches,
    _Page.profile,
  };

  void _go(_Page page, {String? notice}) {
    FocusScope.of(context).unfocus();
    setState(() {
      // Sub-pages return to the tab they were opened from.
      if (_tabPages.contains(page)) _tabOrigin = page;
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
    if (_page == _Page.confirmation) unawaited(_flow.loadAccounts());
    if (_page == _Page.assistantAccounts ||
        (_assistantDestination &&
            (_page == _Page.history ||
                _page == _Page.confirmation ||
                _page == _Page.payments))) {
      _assistantDestination = false;
      _go(_Page.assistant);
      return;
    }
    if (_page == _Page.demoAccount) {
      _openCustomer(_customerId!);
      return;
    }
    if (_page == _Page.editCustomer ||
        (_page == _Page.identity &&
            widget.session.profile?.role == AppRole.officer)) {
      _go(_Page.detail);
    } else if (_page == _Page.detail) {
      _go(_Page.search);
    } else {
      // A tab page goes Home; a sub-page returns to its originating tab.
      _go(_tabPages.contains(_page) ? _Page.home : _tabOrigin);
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
      final customer = profile.role == AppRole.customer;
      final tabs = customer
          ? [
              _Page.home,
              if (_assistant != null) _Page.assistant,
              if (widget.branches != null) _Page.branches,
              _Page.profile,
            ]
          : const <_Page>[];
      final tabIndex = tabs.indexOf(_page);
      return PopScope(
        canPop: _page == _Page.home,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && canBack) _back();
        },
        child: Scaffold(
          bottomNavigationBar: tabIndex < 0
              ? null
              : NavigationBar(
                  selectedIndex: tabIndex,
                  onDestinationSelected: (index) => _go(tabs[index]),
                  destinations: [
                    for (final tab in tabs)
                      switch (tab) {
                        _Page.assistant => const NavigationDestination(
                          icon: Icon(Icons.chat_bubble_outline),
                          selectedIcon: Icon(Icons.chat_bubble),
                          label: 'Assistant',
                        ),
                        _Page.branches => const NavigationDestination(
                          icon: Icon(Icons.map_outlined),
                          selectedIcon: Icon(Icons.map),
                          label: 'Offices',
                        ),
                        _Page.profile => const NavigationDestination(
                          icon: Icon(Icons.person_outline),
                          selectedIcon: Icon(Icons.person),
                          label: 'Profile',
                        ),
                        _ => const NavigationDestination(
                          icon: Icon(Icons.home_outlined),
                          selectedIcon: Icon(Icons.home),
                          label: 'Home',
                        ),
                      },
                  ],
                ),
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leading: canBack && tabIndex < 0
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
            _Page.home =>
              customer ? _customerHome(profile) : _officerHome(profile),
            _Page.profile => _profilePage(profile),
            _Page.assistant => AssistantScreen(
              controller: _assistant!,
              onAction: _openAssistantAction,
            ),
            _Page.assistantAccounts => _assistantAccounts(),
            _Page.payments =>
              widget.security == null
                  ? const WorkspaceContent(
                      children: [
                        Text('This activity is unavailable in this build.'),
                      ],
                    )
                  : PaymentsScreen(
                      api: PaymentsApi(widget.security!),
                      initialService: _paymentService,
                      movies: _moviePayments,
                    ),
            _Page.branches => BranchMapScreen(
              session: widget.session,
              api: widget.branches!,
            ),
            _Page.contact => ContactForm(
              key: const ValueKey('own-contact'),
              profile: profile,
              flow: _flow,
              onSaved: () =>
                  _go(_Page.profile, notice: 'Contact details saved.'),
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
            _Page.confirmation => ConfirmationScreen(
              key: ValueKey(_confirmationAccount!.id),
              api: ConfirmationApi(
                widget.security!,
                sendMoney: _sendDemoMoney,
                cashOperation: _cashOperation,
                interbank: _interbank,
              ),
              account: _confirmationAccount!,
            ),
            _Page.history => AccountHistoryScreen(
              key: ValueKey(_historyAccount!.id),
              session: widget.session,
              api: widget.history!,
              account: _historyAccount!,
              initialMonth: _historyMonth,
            ),
            _Page.demoAccount => DemoAccountScreen(
              session: widget.session,
              api: widget.demoAccounts!,
              customerId: _customerId!,
              customerName: _flow.selectedCustomer!.displayName,
              onDone: () => _openCustomer(_customerId!),
            ),
            _Page.savingsPolicy => SavingsPolicyScreen(
              session: widget.session,
              api: widget.savingsPolicy!,
            ),
            _Page.security => SecurityScreen(api: widget.security!),
            _Page.identity => IdentityReferenceScreen(
              key: ValueKey(_customerId ?? profile.id),
              session: widget.session,
              repository: widget.identity!,
              photos: widget.photos ?? DeviceReferencePhotoSource(),
              customerId: profile.role == AppRole.officer ? _customerId : null,
            ),
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

  /// The customer's main everyday account: the first active VND checking one.
  BankAccount? get _primaryAccount {
    for (final account in _flow.accounts ?? const <BankAccount>[]) {
      if (account.type == 'checking' &&
          account.currency == 'VND' &&
          account.status == 'active') {
        return account;
      }
    }
    return null;
  }

  bool _canMoveMoney(BankAccount account) =>
      widget.security != null &&
      account.currency == 'VND' &&
      account.status == 'active';

  void _openConfirmation(
    BankAccount account, {
    bool interbank = false,
    CashOperation? cash,
  }) {
    _confirmationAccount = account;
    _sendDemoMoney = true;
    _interbank = interbank;
    _cashOperation = cash;
    _go(_Page.confirmation);
  }

  void _openHistory(BankAccount account) {
    _historyAccount = account;
    _historyMonth = null;
    _go(_Page.history);
  }

  void _openPayments({String? service, bool movies = false}) {
    _paymentService = service;
    _moviePayments = movies;
    _assistantDestination = false;
    _go(_Page.payments);
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  Widget _header(UserProfile profile, String subtitle, {Widget? trailing}) =>
      Row(
        children: [
          NeneAvatar(profile.displayName),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subtitle, style: const TextStyle(color: NeneColors.muted)),
                const SizedBox(height: 2),
                Text(
                  profile.displayName,
                  style: Theme.of(context).textTheme.titleLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      );

  Widget _customerHome(UserProfile profile) {
    final accounts = _flow.accounts;
    final primary = _primaryAccount;
    final others = [
      for (final account in accounts ?? const <BankAccount>[])
        if (account.id != primary?.id) account,
    ];
    final send = primary != null && _canMoveMoney(primary);
    return WorkspaceContent(
      children: [
        _header(
          profile,
          _greeting,
          trailing: IconButton(
            tooltip: 'Refresh accounts',
            onPressed: _flow.loadingAccounts ? null : _flow.loadAccounts,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        if (_notice != null) ...[
          const SizedBox(height: 16),
          _Message(_notice!),
        ],
        const SizedBox(height: 20),
        if (_flow.loadingAccounts && accounts == null)
          const _Loading('Loading your accounts'),
        if (_flow.accountsError != null) ...[
          _Message(_flow.accountsError!, error: true),
          TextButton(
            onPressed: _flow.loadAccounts,
            child: const Text('Retry accounts'),
          ),
        ] else if (accounts != null && accounts.isEmpty)
          const _Message(
            'No accounts are linked yet. Your bank officer can help.',
          )
        else if (accounts != null) ...[
          if (primary != null) ...[
            BalanceCard(
              account: primary,
              hidden: _hideBalance,
              onToggleHidden: () =>
                  setState(() => _hideBalance = !_hideBalance),
            ),
            const SizedBox(height: 20),
          ],
          const SectionTitle('Quick actions'),
          QuickActionGrid(
            actions: [
              if (widget.security != null) ...[
                QuickAction(
                  icon: Icons.send_rounded,
                  label: 'Transfer',
                  onTap: send ? () => _openConfirmation(primary) : null,
                ),
                QuickAction(
                  icon: Icons.account_balance_outlined,
                  label: 'Other bank',
                  onTap: send
                      ? () => _openConfirmation(primary, interbank: true)
                      : null,
                ),
                QuickAction(
                  icon: Icons.add_card_outlined,
                  label: 'Deposit',
                  onTap: send
                      ? () => _openConfirmation(
                          primary,
                          cash: CashOperation.deposit,
                        )
                      : null,
                ),
                QuickAction(
                  icon: Icons.payments_outlined,
                  label: 'Withdraw',
                  onTap: send
                      ? () => _openConfirmation(
                          primary,
                          cash: CashOperation.withdrawal,
                        )
                      : null,
                ),
                QuickAction(
                  icon: Icons.receipt_long_outlined,
                  label: 'Bills',
                  onTap: () => _openPayments(),
                ),
                QuickAction(
                  icon: Icons.phone_iphone_rounded,
                  label: 'Top-up',
                  onTap: () => _openPayments(service: 'phone'),
                ),
                QuickAction(
                  icon: Icons.local_movies_outlined,
                  label: 'Movies',
                  onTap: () => _openPayments(movies: true),
                ),
              ],
              if (widget.history != null)
                QuickAction(
                  icon: Icons.history_rounded,
                  label: 'History',
                  onTap: primary == null ? null : () => _openHistory(primary),
                ),
            ],
          ),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 24),
            SectionTitle(primary == null ? 'Your accounts' : 'Other accounts'),
            for (final account in others) ...[
              AccountCard(
                account,
                actions: [
                  if (widget.history != null)
                    TextButton.icon(
                      onPressed: () => _openHistory(account),
                      icon: const Icon(Icons.history_rounded, size: 18),
                      label: const Text('History'),
                    ),
                  if (account.type == 'saving' && _canMoveMoney(account)) ...[
                    TextButton.icon(
                      onPressed: () => _openConfirmation(
                        account,
                        cash: CashOperation.deposit,
                      ),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Deposit'),
                    ),
                    TextButton.icon(
                      onPressed: () => _openConfirmation(
                        account,
                        cash: CashOperation.withdrawal,
                      ),
                      icon: const Icon(Icons.remove_rounded, size: 18),
                      label: const Text('Withdraw'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
            ],
          ],
        ],
        if (widget.security != null) ...[
          const SizedBox(height: 12),
          NeneBanner(
            icon: Icons.verified_user_outlined,
            title: 'Transaction security',
            body: 'Your authenticator approves every transfer and payment.',
            onTap: () => _go(_Page.security),
          ),
        ],
        const SizedBox(height: 20),
        const Text(
          'Educational banking project · synthetic money only. Identity '
          'verification (eKYC) is not completed in this demo. Bills, top-ups '
          'and tickets use the VNPay sandbox and never settle real services.',
          textAlign: TextAlign.center,
          style: TextStyle(color: NeneColors.muted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _officerHome(UserProfile profile) => WorkspaceContent(
    children: [
      _header(profile, 'Officer workspace'),
      if (_notice != null) ...[const SizedBox(height: 16), _Message(_notice!)],
      const SizedBox(height: 24),
      const SectionTitle('Help a customer'),
      ActionTile(
        icon: Icons.person_add_alt_1_outlined,
        title: 'Create customer',
        body: 'Open a customer profile and their first checking account.',
        emphasized: true,
        onTap: () => _go(_Page.create),
      ),
      const SizedBox(height: 12),
      ActionTile(
        icon: Icons.manage_search_rounded,
        title: 'Find a customer',
        body: 'Edit requested details, review a photo or add demo accounts.',
        onTap: () => _go(_Page.search),
      ),
      if (widget.savingsPolicy != null) ...[
        const SizedBox(height: 24),
        const SectionTitle('Bank policy'),
        ActionTile(
          icon: Icons.percent_rounded,
          title: 'Manage savings rate',
          body: 'Change the annual savings rate under the bank policy.',
          onTap: () => _go(_Page.savingsPolicy),
        ),
      ],
      const SizedBox(height: 24),
      const SectionTitle('My profile'),
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
          child: _Info('Email', profile.email ?? 'Not provided'),
        ),
      ),
    ],
  );

  Widget _profilePage(UserProfile profile) => WorkspaceContent(
    children: [
      if (_notice != null) ...[_Message(_notice!), const SizedBox(height: 16)],
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  NeneAvatar(profile.displayName, size: 56),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.displayName,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          profile.email ?? 'Not provided',
                          style: const TextStyle(color: NeneColors.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Divider(),
              ),
              _Info('Phone', profile.phone ?? 'Not provided'),
              _Info('Address', profile.address ?? 'Not provided'),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit contact details'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                _flow.clearContactError();
                _go(_Page.contact);
              },
            ),
            if (widget.security != null) ...[
              const Divider(),
              ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('Transaction security'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _go(_Page.security),
              ),
            ],
            if (widget.identity != null) ...[
              const Divider(),
              ListTile(
                leading: const Icon(Icons.portrait_outlined),
                title: const Text('Identity reference'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _go(_Page.identity),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: widget.session.signOut,
        style: OutlinedButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.error,
        ),
        icon: const Icon(Icons.logout),
        label: const Text('Sign out of Nene'),
      ),
    ],
  );

  void _openAssistantAction(AssistantAction action) {
    if (action.activity == AssistantActivity.bills ||
        action.activity == AssistantActivity.phone ||
        action.activity == AssistantActivity.movieTickets) {
      _assistantDestination = true;
      _moviePayments = action.activity == AssistantActivity.movieTickets;
      _paymentService = switch (action.activity) {
        AssistantActivity.phone => 'phone',
        AssistantActivity.bills => 'electricity',
        _ => null,
      };
      _go(_Page.payments);
      return;
    }
    _assistantAction = action;
    _go(_Page.assistantAccounts);
    unawaited(_flow.loadAccounts());
  }

  Widget _assistantAccounts() {
    final action = _assistantAction!;
    final history = action.activity == AssistantActivity.history;
    final available = history
        ? widget.history != null
        : widget.security != null;
    final accounts = (_flow.accounts ?? <BankAccount>[])
        .where(
          (a) =>
              history ||
              (a.status == 'active' &&
                  a.currency == 'VND' &&
                  ([
                        AssistantActivity.transfer,
                        AssistantActivity.interbankTransfer,
                      ].contains(action.activity)
                      ? a.type == 'checking'
                      : ['checking', 'saving'].contains(a.type))),
        )
        .toList();
    return WorkspaceContent(
      children: [
        Text(
          'Choose your account',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        Text(
          history
              ? 'Transaction history for ${action.month}'
              : 'Open the normal ${action.activity == AssistantActivity.interbankTransfer ? 'other-bank demo transfer' : action.activity.name} flow. Nothing has been submitted.',
        ),
        const SizedBox(height: 16),
        if (!available)
          const Text('This activity is unavailable in this build.'),
        if (available && _flow.loadingAccounts)
          const _Loading('Loading your accounts'),
        if (available && _flow.accountsError != null) ...[
          _Message(_flow.accountsError!, error: true),
          TextButton(
            onPressed: _flow.loadingAccounts ? null : _flow.loadAccounts,
            child: const Text('Retry accounts'),
          ),
        ],
        if (available &&
            !_flow.loadingAccounts &&
            _flow.accountsError == null) ...[
          if (accounts.isEmpty)
            const Text('No eligible accounts are available for this activity.'),
          for (final account in accounts)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton(
                onPressed: () {
                  _assistantDestination = true;
                  if (history) {
                    _historyAccount = account;
                    _historyMonth = action.month;
                    _go(_Page.history);
                  } else {
                    _confirmationAccount = account;
                    _sendDemoMoney = true;
                    _interbank =
                        action.activity == AssistantActivity.interbankTransfer;
                    _cashOperation = switch (action.activity) {
                      AssistantActivity.deposit => CashOperation.deposit,
                      AssistantActivity.withdrawal => CashOperation.withdrawal,
                      _ => null,
                    };
                    _go(_Page.confirmation);
                  }
                },
                child: Text('${account.typeLabel} · ${account.accountNumber}'),
              ),
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
            for (final account in customer.accounts) AccountCard(account),
          if (widget.demoAccounts != null)
            OutlinedButton.icon(
              onPressed: () => _go(_Page.demoAccount),
              icon: const Icon(Icons.add),
              label: const Text('Add demo account'),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              _flow.clearCustomerSaveError();
              _go(_Page.editCustomer);
            },
            child: const Text('Make a requested change'),
          ),
          if (widget.identity != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _go(_Page.identity),
              icon: const Icon(Icons.portrait_outlined),
              label: const Text('Assist / review reference'),
            ),
          ],
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

class AccountCard extends StatelessWidget {
  const AccountCard(this.account, {super.key, this.actions = const []});
  final BankAccount account;
  final List<Widget> actions;

  IconData get _icon => switch (account.type) {
    'saving' => Icons.savings_outlined,
    'mortgage' => Icons.home_work_outlined,
    _ => Icons.account_balance_wallet_outlined,
  };

  @override
  Widget build(BuildContext context) {
    const muted = TextStyle(color: NeneColors.muted, fontSize: 13);
    const amount = TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      fontFeatures: neneTabularFigures,
    );
    final mortgage = account.type == 'mortgage';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: NeneColors.pale,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(_icon, color: NeneColors.action),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.typeLabel,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      SelectableText(
                        account.accountNumber,
                        style: muted.copyWith(
                          letterSpacing: 0.8,
                          fontFeatures: neneTabularFigures,
                        ),
                      ),
                    ],
                  ),
                ),
                _AccountStatus(account.status),
              ],
            ),
            const SizedBox(height: 16),
            if (mortgage) ...[
              const Text('Monthly repayment', style: muted),
              const SizedBox(height: 2),
              Text(
                account.monthlyDueMinor == null
                    ? 'Repayment schedule unavailable'
                    : account.amountLabel(account.monthlyDueMinor!),
                style: amount,
              ),
              const SizedBox(height: 8),
              if (account.nextDueOn != null)
                Text('Next due: ${account.nextDueOn}'),
              if (account.principalRemainingMinor != null)
                Text(
                  'Principal remaining: ${account.amountLabel(account.principalRemainingMinor!)}',
                  style: muted,
                ),
              const Text(
                'Monthly schedule. Repayment is not available yet.',
                style: muted,
              ),
            ] else ...[
              const Text('Balance', style: muted),
              const SizedBox(height: 2),
              Text(account.balanceLabel, style: amount),
            ],
            if (account.type == 'saving') ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: NeneColors.pale,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.annualRateBps == null
                          ? 'Savings rate unavailable'
                          : 'Annual rate: ${(account.annualRateBps! / 100).toStringAsFixed(2)}%',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      account.monthlyProfitMinor == null
                          ? 'Monthly estimate unavailable'
                          : 'Estimated monthly profit: ${account.amountLabel(account.monthlyProfitMinor!)}',
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Estimate at the current balance and rate. No interest has been credited.',
                      style: muted,
                    ),
                  ],
                ),
              ),
            ],
            if (account.isDemo) ...[
              const SizedBox(height: 10),
              Text(
                mortgage
                    ? 'Synthetic demo · 0% sample schedule · no loan issued'
                    : 'Synthetic demo account · no money deposited',
                style: muted,
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(),
              TextButtonTheme(
                data: TextButtonThemeData(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
                child: Wrap(children: actions),
              ),
            ] else
              const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}

class _AccountStatus extends StatelessWidget {
  const _AccountStatus(this.status);
  final String status;

  @override
  Widget build(BuildContext context) {
    final active = status == 'active';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFE3F3EA) : NeneColors.line,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        active ? 'Active' : status,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: active ? NeneColors.positive : NeneColors.muted,
        ),
      ),
    );
  }
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
