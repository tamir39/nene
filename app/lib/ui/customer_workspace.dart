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
import '../data/face_check.dart';
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
    this.faceCheck,
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
  final FaceCheck? faceCheck;
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

  // Customer tabs plus the officer-only Customers and Rates tabs.
  static const _tabPages = {
    _Page.home,
    _Page.assistant,
    _Page.branches,
    _Page.profile,
    _Page.search,
    _Page.savingsPolicy,
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
          : [
              _Page.home,
              _Page.search,
              if (widget.savingsPolicy != null) _Page.savingsPolicy,
              _Page.profile,
            ];
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
                        _Page.search => const NavigationDestination(
                          icon: Icon(Icons.people_outline),
                          selectedIcon: Icon(Icons.people),
                          label: 'Customers',
                        ),
                        _Page.savingsPolicy => const NavigationDestination(
                          icon: Icon(Icons.percent_rounded),
                          label: 'Rates',
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
              photos: widget.photos,
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
              faceCheck: widget.faceCheck ?? createDeviceFaceCheck(),
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
                        if (profile.role == AppRole.officer) ...[
                          const SizedBox(height: 8),
                          const Chip(
                            avatar: Icon(Icons.badge_outlined, size: 18),
                            label: Text('Bank officer'),
                            backgroundColor: NeneColors.apricotSoft,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (profile.role == AppRole.customer) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Divider(),
                ),
                _Info('Phone', profile.phone ?? 'Not provided'),
                _Info('Address', profile.address ?? 'Not provided'),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      if (profile.role == AppRole.customer) ...[
        _customerSettings(),
        const SizedBox(height: 16),
      ],
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

  Widget _customerSettings() => Card(
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
        const _Heading('Choose your account'),
        _Lead(
          history
              ? 'Transaction history for ${action.month}'
              : 'Open the normal ${action.activity == AssistantActivity.interbankTransfer ? 'other-bank demo transfer' : action.activity.name} flow. Nothing has been submitted.',
        ),
        if (!available)
          const _Message('This activity is unavailable in this build.'),
        if (available && _flow.loadingAccounts)
          const _Loading('Loading your accounts'),
        if (available && _flow.accountsError != null) ...[
          _Message(_flow.accountsError!, error: true),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _flow.loadingAccounts ? null : _flow.loadAccounts,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry accounts'),
          ),
        ],
        if (available &&
            !_flow.loadingAccounts &&
            _flow.accountsError == null) ...[
          if (accounts.isEmpty)
            const _EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              title: 'No eligible accounts are available for this activity.',
              body: 'Go back to the assistant to choose another activity.',
            ),
          for (final account in accounts) ...[
            _TapCard(
              leading: _IconBadge(_accountIcon(account.type)),
              // Width goes to the label so "Type · number" stays on one line.
              chevron: false,
              onTap: () {
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
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: account.typeLabel,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: ' · ${account.accountNumber}',
                        style: const TextStyle(
                          color: NeneColors.muted,
                          fontSize: 13.5,
                          fontFeatures: neneTabularFigures,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ],
      ],
    );
  }

  Widget _detail() {
    final customer = _flow.selectedCustomer;
    return WorkspaceContent(
      children: [
        const _Heading('Customer details'),
        const _Lead('Profile, accounts and requested changes.'),
        if (_notice != null) ...[
          _Message(_notice!),
          const SizedBox(height: 16),
        ],
        if (_flow.loadingCustomer) const _Loading('Loading customer'),
        if (_flow.customerError != null) ...[
          _Message(_flow.customerError!, error: true),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => _flow.loadCustomer(_customerId!),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry customer'),
          ),
        ],
        if (customer != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      NeneAvatar(customer.displayName, size: 56),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              customer.displayName,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 2),
                            SelectableText(
                              customer.email ?? 'Not provided',
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
                  _Info('Phone', customer.phone ?? 'Not provided'),
                  _Info('Address', customer.address ?? 'Not provided'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _Message(
            'Identity is unverified. Creating a customer does not complete eKYC '
            'or enable money movements.',
          ),
          const SizedBox(height: 24),
          const SectionTitle('Accounts'),
          if (customer.accounts.isEmpty)
            const _EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              title: 'No linked accounts.',
              body: 'Accounts opened for this customer appear here.',
            )
          else
            for (final account in customer.accounts) ...[
              AccountCard(account),
              const SizedBox(height: 12),
            ],
          const SizedBox(height: 12),
          const SectionTitle('Officer actions'),
          ActionTile(
            icon: Icons.edit_note_rounded,
            title: 'Make a requested change',
            body: 'Update the name, phone or address the customer asked for.',
            emphasized: true,
            onTap: () {
              _flow.clearCustomerSaveError();
              _go(_Page.editCustomer);
            },
          ),
          if (widget.identity != null) ...[
            const SizedBox(height: 12),
            ActionTile(
              icon: Icons.portrait_outlined,
              title: 'Assist / review reference',
              body: 'Help capture or review the private reference photo.',
              onTap: () => _go(_Page.identity),
            ),
          ],
          if (widget.demoAccounts != null) ...[
            const SizedBox(height: 12),
            ActionTile(
              icon: Icons.add_card_outlined,
              title: 'Add demo account',
              body: 'Add a synthetic savings or mortgage account for testing.',
              onTap: () => _go(_Page.demoAccount),
            ),
          ],
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () => _go(_Page.search),
            icon: const Icon(Icons.manage_search_rounded),
            label: const Text('Find another customer'),
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
      const _Lead(
        'You can update your phone and address. Leave a field blank to '
        'remove it.',
      ),
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FormCard(
              children: [
                _ContactFields(
                  phone: _phone,
                  address: _address,
                  enabled: !widget.flow.savingContact,
                ),
              ],
            ),
            const SizedBox(height: 16),
            const _Note(
              Icons.support_agent_outlined,
              'Contact your officer for a name or sign-in email correction.',
            ),
            if (widget.flow.contactError != null) ...[
              const SizedBox(height: 16),
              _Message(widget.flow.contactError!, error: true),
            ],
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
        _Lead(
          reviewing
              ? 'Check the details before you confirm.'
              : 'Open a profile and a first checking account.',
        ),
        _Steps(reviewing ? 1 : 0),
        const SizedBox(height: 20),
        const _Message(
          'This demo creates one VND checking account with a zero balance. '
          'Money movements stay locked until a reference photo is accepted '
          'and the customer sets up an authenticator.',
        ),
        const SizedBox(height: 16),
        if (reviewing) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SummaryRow('Name', _name.text.trim()),
                  const Divider(),
                  _SummaryRow(
                    'Sign-in email',
                    _email.text.trim().toLowerCase(),
                  ),
                  const Divider(),
                  _SummaryRow(
                    'Phone',
                    _nullable(_phone.text) ?? 'Not provided',
                  ),
                  const Divider(),
                  _SummaryRow(
                    'Address',
                    _nullable(_address.text) ?? 'Not provided',
                  ),
                  const Divider(),
                  const _SummaryRow('Initial password', 'Set · hidden'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const _Note(
            Icons.privacy_tip_outlined,
            'Use synthetic details for this project demo. Share the access '
            'details privately with the customer. There is no invitation email '
            'or password-reset flow in this slice.',
          ),
          if (widget.flow.creationError != null) ...[
            const SizedBox(height: 16),
            _Message(widget.flow.creationError!, error: true),
          ],
          if (widget.flow.hasCreationAttempt) ...[
            const SizedBox(height: 12),
            const _Note(
              Icons.warning_amber_rounded,
              'Do not close or sign out until the outcome is confirmed. Pending '
              'request details are kept only in memory. If the session ends, '
              'find the customer by email before attempting another creation.',
              caution: true,
            ),
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
                  widget.flow.canCorrectCreation)) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: _edit, child: const Text('Edit details')),
          ],
        ] else
          Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _FormCard(
                  title: 'Personal details',
                  children: [
                    _NameField(controller: _name),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _email,
                      decoration: const InputDecoration(
                        labelText: 'Sign-in email',
                        helperText: 'The customer signs in with this email.',
                        prefixIcon: Icon(Icons.alternate_email_rounded),
                        counterText: '',
                      ),
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
                  ],
                ),
                const SizedBox(height: 16),
                _FormCard(
                  title: 'Contact',
                  children: [_ContactFields(phone: _phone, address: _address)],
                ),
                const SizedBox(height: 16),
                _FormCard(
                  title: 'Sign-in',
                  children: [
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
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        suffixIcon: IconButton(
                          tooltip: _hidePassword
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: () =>
                              setState(() => _hidePassword = !_hidePassword),
                          icon: Icon(
                            _hidePassword
                                ? Icons.visibility
                                : Icons.visibility_off,
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
                  ],
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
  Widget build(BuildContext context) {
    final customers = widget.flow.customers;
    return WorkspaceContent(
      children: [
        const _Heading('Find a customer'),
        const _Lead('Search by name or sign-in email.'),
        TextField(
          controller: _query,
          decoration: const InputDecoration(
            labelText: 'Name or email',
            prefixIcon: Icon(Icons.search_rounded),
            counterText: '',
          ),
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
        else if (customers == null)
          const _EmptyState(
            icon: Icons.manage_search_rounded,
            title: 'Search to get started',
            body: 'Enter a name or email to find a customer.',
          )
        else if (customers.isEmpty)
          const _EmptyState(
            icon: Icons.person_search_outlined,
            title: 'No customers found',
            body: 'Check the name or email and try again.',
          )
        else ...[
          SectionTitle(
            customers.length == 1
                ? '1 customer'
                : '${customers.length} customers',
          ),
          for (final customer in customers) ...[
            _TapCard(
              leading: NeneAvatar(customer.displayName),
              onTap: () => widget.onOpen(customer.id),
              children: [
                Text(
                  customer.displayName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  customer.email ?? 'No email available',
                  style: const TextStyle(color: NeneColors.muted, fontSize: 13),
                ),
                const SizedBox(height: 6),
                const Text(
                  'View customer',
                  style: TextStyle(
                    color: NeneColors.action,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 4),
          const _Note(
            Icons.info_outline_rounded,
            'Showing up to 20 matches. Use a more specific name or email if '
            'needed.',
          ),
        ],
      ],
    );
  }
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
      const _Lead('Make only the changes the customer requested.'),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: NeneColors.pale,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _IconBadge(Icons.lock_outline_rounded, light: true),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sign-in email',
                    style: TextStyle(color: NeneColors.muted, fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    widget.customer.email ?? 'Not provided',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Sign-in email changes are not supported in this demo.',
                    style: TextStyle(color: NeneColors.muted, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FormCard(
              title: 'Requested details',
              children: [
                _NameField(
                  controller: _name,
                  enabled: !widget.flow.savingCustomer,
                ),
                const SizedBox(height: 16),
                _ContactFields(
                  phone: _phone,
                  address: _address,
                  enabled: !widget.flow.savingCustomer,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _FormCard(
              title: 'Customer request',
              children: [
                TextFormField(
                  controller: _reason,
                  enabled: !widget.flow.savingCustomer,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Customer request / reason',
                    helperText:
                        'Describe the requested change (5–500 characters).',
                    helperMaxLines: 4,
                    prefixIcon: Icon(Icons.notes_rounded),
                  ),
                  validator: (value) =>
                      value != null &&
                          value.trim().length >= 5 &&
                          value.trim().length <= 500 &&
                          !_hasControl(value)
                      ? null
                      : 'Enter a reason of 5–500 characters.',
                ),
              ],
            ),
            if (widget.flow.customerSaveError != null) ...[
              const SizedBox(height: 16),
              _Message(widget.flow.customerSaveError!, error: true),
            ],
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
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextFormField(
        controller: phone,
        enabled: enabled,
        decoration: const InputDecoration(
          labelText: 'Phone (optional)',
          helperText: 'Digits, spaces, +, (, ) or -.',
          prefixIcon: Icon(Icons.phone_outlined),
          counterText: '',
        ),
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
      const SizedBox(height: 16),
      TextFormField(
        controller: address,
        enabled: enabled,
        decoration: const InputDecoration(
          labelText: 'Address (optional)',
          prefixIcon: Icon(Icons.home_outlined),
        ),
        textInputAction: TextInputAction.next,
        maxLength: 300,
        validator: (value) =>
            value == null || (value.trim().length <= 300 && !_hasControl(value))
            ? null
            : 'Use up to 300 characters without control characters.',
      ),
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
    decoration: const InputDecoration(
      labelText: 'Full name',
      prefixIcon: Icon(Icons.person_outline_rounded),
      counterText: '',
    ),
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
              _MortgageRepayment(
                account,
                key: ValueKey(account.id),
                labelStyle: muted,
                amountStyle: amount,
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

/// Switches between the stored monthly amount and the backend-derived two-week
/// equivalent (same yearly total over 26 payments). The toggle is hidden when
/// the response has no two-week amount, e.g. from an older API.
class _MortgageRepayment extends StatefulWidget {
  const _MortgageRepayment(
    this.account, {
    super.key,
    required this.labelStyle,
    required this.amountStyle,
  });
  final BankAccount account;
  final TextStyle labelStyle, amountStyle;

  @override
  State<_MortgageRepayment> createState() => _MortgageRepaymentState();
}

class _MortgageRepaymentState extends State<_MortgageRepayment> {
  static const _twoWeekOption = 'Every 2 weeks';
  var _twoWeeks = false;

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final monthly = account.monthlyDueMinor;
    final twoWeek = monthly == null ? null : account.biweeklyDueMinor;
    final showTwoWeeks = _twoWeeks && twoWeek != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (twoWeek != null) ...[
          LayoutBuilder(
            builder: (context, constraints) =>
                _toggle(context, constraints.maxWidth),
          ),
          const SizedBox(height: 12),
        ],
        Text(
          showTwoWeeks ? 'Repayment every 2 weeks' : 'Monthly repayment',
          style: widget.labelStyle,
        ),
        const SizedBox(height: 2),
        Text(
          monthly == null
              ? 'Repayment schedule unavailable'
              : account.amountLabel(showTwoWeeks ? twoWeek : monthly),
          style: widget.amountStyle,
        ),
        if (showTwoWeeks) ...[
          const SizedBox(height: 4),
          Text(
            'Equivalent of the monthly schedule: the same yearly total '
            'over 26 payments, rounded up.',
            style: widget.labelStyle,
          ),
        ],
      ],
    );
  }

  Widget _toggle(BuildContext context, double width) {
    // Stack the segments when large text would not fit them side by side.
    final label = TextPainter(
      text: TextSpan(
        text: _twoWeekOption,
        style: Theme.of(context).textTheme.labelLarge,
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final sideBySide = 2 * (label.width + 32) <= width;
    label.dispose();
    final toggle = SegmentedButton<bool>(
      direction: sideBySide ? Axis.horizontal : Axis.vertical,
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        foregroundColor: NeneColors.muted,
        selectedForegroundColor: NeneColors.action,
        selectedBackgroundColor: NeneColors.pale,
        side: const BorderSide(color: NeneColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      segments: const [
        ButtonSegment(value: false, label: Text('Monthly')),
        ButtonSegment(value: true, label: Text(_twoWeekOption)),
      ],
      selected: {_twoWeeks},
      onSelectionChanged: (selection) =>
          setState(() => _twoWeeks = selection.single),
    );
    // Stacked segments use the full card width so labels keep clear margins.
    return sideBySide
        ? toggle
        : SizedBox(width: double.infinity, child: toggle);
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
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.headlineSmall),
  );
}

/// One-line explanation under a page [_Heading].
class _Lead extends StatelessWidget {
  const _Lead(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Text(text, style: const TextStyle(color: NeneColors.muted)),
  );
}

/// Tinted banner: pale teal with an info icon, or soft red for errors.
class _Message extends StatelessWidget {
  const _Message(this.text, {this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
        decoration: BoxDecoration(
          color: error ? const Color(0xFFFBEDEC) : NeneColors.pale,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              size: 20,
              color: error ? errorColor : NeneColors.action,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: error ? errorColor : NeneColors.ink,
                  fontSize: 13.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 32,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            semanticsLabel: label,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(color: NeneColors.muted),
        ),
      ],
    ),
  );
}

/// White card that groups related form fields under an optional title.
class _FormCard extends StatelessWidget {
  const _FormCard({this.title, required this.children});
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
          ],
          ...children,
        ],
      ),
    ),
  );
}

/// Secondary guidance with a leading icon; [caution] tints it apricot.
class _Note extends StatelessWidget {
  const _Note(this.icon, this.text, {this.caution = false});
  final IconData icon;
  final String text;
  final bool caution;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: caution ? 20 : 18,
          color: caution ? NeneColors.deep : NeneColors.muted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: caution ? NeneColors.ink : NeneColors.muted,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
    if (!caution) return row;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
      decoration: BoxDecoration(
        color: NeneColors.apricotSoft,
        borderRadius: BorderRadius.circular(16),
      ),
      child: row,
    );
  }
}

/// Two-step progress for customer creation: details, then review.
class _Steps extends StatelessWidget {
  const _Steps(this.current);
  final int current;

  static const _labels = ['Details', 'Review'];

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Step ${current + 1} of 2: ${_labels[current]}',
    child: ExcludeSemantics(
      child: Row(
        children: [
          for (var i = 0; i < _labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: i <= current ? NeneColors.action : NeneColors.line,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${i + 1}. ${_labels[i]}',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: i == current
                          ? NeneColors.action
                          : NeneColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

/// Label/value line of a review summary. Label and value share one line when
/// both fit; otherwise the value moves below its label instead of breaking
/// mid-word (long emails, enlarged text).
class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value);
  final String label;
  final String value;

  static const _gap = 16.0;
  static const _labelStyle = TextStyle(color: NeneColors.muted);
  static const _valueStyle = TextStyle(fontWeight: FontWeight.w600);

  double _width(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 14),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final inline =
            _width(context, label, _labelStyle) +
                _gap +
                _width(context, value, _valueStyle) <=
            constraints.maxWidth;
        if (!inline) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: _labelStyle),
              const SizedBox(height: 4),
              Text(value, style: _valueStyle),
            ],
          );
        }
        return Row(
          children: [
            Text(label, style: _labelStyle),
            const SizedBox(width: _gap),
            Expanded(
              child: Text(value, textAlign: TextAlign.end, style: _valueStyle),
            ),
          ],
        );
      },
    ),
  );
}

/// Centered icon, title and hint for empty or not-yet-started lists.
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: NeneColors.pale,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(icon, size: 30, color: NeneColors.action),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(color: NeneColors.muted, fontSize: 13.5),
        ),
      ],
    ),
  );
}

/// Tappable white card row with a leading visual and a trailing chevron.
class _TapCard extends StatelessWidget {
  const _TapCard({
    required this.leading,
    required this.onTap,
    required this.children,
    this.chevron = true,
  });
  final Widget leading;
  final VoidCallback onTap;
  final List<Widget> children;
  final bool chevron;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      button: true,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: NeneColors.line),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: children,
                  ),
                ),
                if (chevron) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right, color: NeneColors.muted),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Tinted rounded-square icon container used across the workspace.
class _IconBadge extends StatelessWidget {
  const _IconBadge(this.icon, {this.light = false});
  final IconData icon;
  final bool light;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      color: light ? Colors.white : NeneColors.pale,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Icon(icon, color: NeneColors.action),
  );
}

IconData _accountIcon(String type) => switch (type) {
  'saving' => Icons.savings_outlined,
  'mortgage' => Icons.home_work_outlined,
  _ => Icons.account_balance_wallet_outlined,
};

String? _nullable(String text) => text.trim().isEmpty ? null : text.trim();
bool _hasControl(String text) => RegExp(r'[\x00-\x1f\x7f]').hasMatch(text);
