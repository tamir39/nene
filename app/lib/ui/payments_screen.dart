import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/payments_api.dart';
import '../data/session_owner.dart';
import 'customer_workspace.dart' show WorkspaceContent;
import 'nene_brand.dart';
import 'nene_components.dart' show NeneBanner, SectionTitle;

class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({
    super.key,
    required this.api,
    this.initialService,
    this.movies = false,
    this.openCheckout,
  });
  final PaymentsApi api;
  final String? initialService;
  final bool movies;
  final Future<bool> Function(Uri)? openCheckout;
  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen>
    with WidgetsBindingObserver {
  final _code = TextEditingController();
  PaymentConfiguration? _configuration;
  List<PaymentOrder> _recent = [];
  PaymentReview? _review;
  PaymentPreview? _preview;
  PaymentStatus? _status;
  String? _requestId, _error;
  bool _busy = false, _attempted = false, _expired = false, _hidden = false;
  Timer? _expiry;
  // Catalog presentation only: the highlighted service tile/card.
  late String? _focus = widget.initialService;
  final _cardKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run(_load));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    _code.dispose();
    _review = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() {
      _hidden = state != AppLifecycleState.resumed;
      if (_hidden) _code.clear();
    });
  }

  Future<void> _load() async {
    final configuration = await widget.api.configuration();
    final recent = await widget.api.recent();
    if (!mounted) return;
    setState(() {
      _configuration = configuration;
      _recent = recent;
    });
  }

  Future<void> _run(
    Future<void> Function() work, {
    bool confirming = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on SessionMutationRejected {
      if (mounted) {
        setState(() {
          if (confirming) _status = const PaymentStatus(state: 'rejected');
          _error = confirming
              ? 'Confirmation was not accepted. Check status before a new review, and use a fresh authenticator code. After too many attempts, wait 15 minutes.'
              : 'This request is unavailable. Check recent payments first: an unfinished checkout or an already paid demo bill cannot be started again. Checkout also needs an accepted, unexpired reference photo and a ready authenticator.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          if (confirming) _status = const PaymentStatus(state: 'unknown');
          _error = confirming
              ? 'Confirmation outcome is uncertain. Sign in again and check recent payments before starting another checkout. Do not repeat this code.'
              : 'Payments could not be loaded. Try again, or sign in again if your session has ended.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare(PaymentServiceOffer service) => _run(() async {
    final review = await widget.api.review(service.id, expected: service);
    if (!mounted) return;
    setState(() {
      _review = review;
      _preview = null;
      _requestId = review.requestId;
      _status = null;
      _attempted = false;
      _expired = !review.expiresAt.isAfter(DateTime.now());
      _code.clear();
    });
    _expiry?.cancel();
    if (!_expired) {
      _expiry = Timer(review.expiresAt.difference(DateTime.now()), () {
        if (!mounted || _attempted) return;
        setState(() {
          _expired = true;
          _code.clear();
        });
      });
    }
  });

  Future<void> _previewOffer(PaymentServiceOffer service) => _run(() async {
    final preview = await widget.api.preview(service.id);
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _review = null;
      _status = null;
      _requestId = null;
      _code.clear();
    });
  });

  Future<void> _confirm() async {
    final review = _review;
    if (review == null || _attempted || _expired || _hidden) return;
    final code = _code.text.trim();
    _code.clear();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter a six-digit authenticator code.');
      return;
    }
    if (!review.expiresAt.isAfter(DateTime.now())) {
      setState(() => _expired = true);
      return;
    }
    setState(() => _attempted = true);
    _expiry?.cancel();
    await _run(() async {
      final status = await widget.api.confirm(review, code);
      if (!mounted) return;
      setState(() {
        _status = status;
        _review = null; // The signed review is single-attempt, never persisted.
      });
    }, confirming: true);
  }

  Future<void> _check(String id) => _run(() async {
    final status = await widget.api.status(id);
    if (!mounted) return;
    setState(() {
      _requestId = id;
      _status = status;
      _review = null;
      _preview = null;
      _attempted = true;
      _code.clear();
    });
    _expiry?.cancel();
  });

  Future<void> _open() async {
    final status = _status;
    final order = status?.order;
    if (_busy ||
        status?.checkoutUrl == null ||
        order == null ||
        order.state != 'awaiting_payment') {
      return;
    }
    if (!order.expiresAt.isAfter(DateTime.now())) {
      setState(
        () => _error =
            'This checkout link has expired. Check payment status before starting another.',
      );
      return;
    }
    // Only an explicit tap opens the external sandbox, after session adoption.
    // The backend URL is checked again at the navigation boundary.
    try {
      final uri = checkedCheckoutUrl(status!.checkoutUrl.toString());
      final opened =
          await (widget.openCheckout?.call(uri) ??
              launchUrl(
                uri,
                mode: LaunchMode.externalApplication,
                webOnlyWindowName: '_blank',
              ));
      if (!opened && mounted) {
        setState(
          () => _error =
              'The sandbox window could not open. Allow the new tab and try Open VNPay sandbox again.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'The sandbox window could not open. Check payment status before trying again.',
        );
      }
    }
  }

  void _catalog() {
    _expiry?.cancel();
    setState(() {
      _review = null;
      _preview = null;
      _status = null;
      _requestId = null;
      _attempted = false;
      _expired = false;
      _error = null;
      _code.clear();
    });
    unawaited(_run(_load));
  }

  /// Highlights a service and brings its bill card into view. Presentation
  /// only: every card stays listed and keeps its own review action.
  void _focusService(String id) {
    setState(() => _focus = id);
    final target = _cardKeys[id]?.currentContext;
    if (target == null) return;
    unawaited(
      Scrollable.ensureVisible(
        target,
        alignment: .05,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      Text(
        widget.movies ? 'Movie tickets demo' : 'Bills & phone demo',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 16),
      NeneBanner(
        icon: widget.movies
            ? Icons.local_movies_outlined
            : Icons.science_outlined,
        title: widget.movies
            ? 'Fictional cinema · sandbox only'
            : 'Fictional services · sandbox only',
        body: widget.movies
            ? 'Explore two fictional one-ticket offers. No real showing, seat reservation or admission is provided. Your Nene balance is unchanged.'
            : 'Try electricity, water and phone checkout with test data. No real bill is settled, no phone credit is delivered and your Nene balance is unchanged.',
      ),
      // Reserved height keeps the page from jumping while requests run.
      SizedBox(
        height: 20,
        child: _busy
            ? const Center(
                child: LinearProgressIndicator(
                  semanticsLabel: 'Loading payments',
                  minHeight: 4,
                  borderRadius: BorderRadius.all(Radius.circular(99)),
                ),
              )
            : null,
      ),
      if (_error != null) ...[_Alert(_error!), const SizedBox(height: 16)],
      if (_status != null)
        ..._statusView(context)
      else if (_review != null)
        ..._reviewView(context)
      else if (_preview != null)
        ..._previewView(context)
      else
        ..._catalogView(context),
    ],
  );

  List<Widget> _catalogView(BuildContext context) {
    final config = _configuration;
    final services = [
      ...?config?.services,
    ].where((service) => service.isMovie == widget.movies).toList();
    final recent = _recent
        .where((order) => order.service.isMovie == widget.movies)
        .toList();
    // Picker tiles keep the catalog order; only the cards move a preset first.
    final picker = [...services];
    if (widget.initialService != null) {
      services.sort(
        (a, b) => (a.id == widget.initialService ? 0 : 1).compareTo(
          b.id == widget.initialService ? 0 : 1,
        ),
      );
    }
    return [
      if (config != null && !config.enabled) ...[
        const _InfoCard(
          icon: Icons.hourglass_top_rounded,
          title: 'Sandbox setup pending',
          text:
              'The demo catalog is ready. Checkout stays disabled until the project team configures VNPay sandbox credentials and a verified callback address.',
        ),
        const SizedBox(height: 24),
      ],
      if (config != null && config.enabled) ...[
        const _HowItWorks(),
        const SizedBox(height: 24),
      ],
      if (config != null) ...[
        SectionTitle(widget.movies ? 'Ticket offers' : 'Choose a service'),
        if (!widget.movies && picker.length > 1) ...[
          Row(
            children: [
              for (final (index, service) in picker.indexed) ...[
                if (index > 0) const SizedBox(width: 10),
                Expanded(
                  child: _ServiceTile(
                    service: service,
                    selected: _focus == service.id,
                    onTap: () => _focusService(service.id),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (services.isEmpty)
          _EmptyState(
            icon: widget.movies
                ? Icons.local_movies_outlined
                : Icons.receipt_long_outlined,
            title: 'No demo offers right now',
            text: 'Refresh to load the sandbox catalog again.',
          ),
        for (final service in services) ...[
          _OfferCard(
            key: _cardKeys.putIfAbsent(service.id, GlobalKey.new),
            service: service,
            highlighted: !widget.movies && _focus == service.id,
            blocked: _blocked(service),
            action: OutlinedButton(
              style: _tonalButton,
              onPressed:
                  _busy ||
                      (!widget.movies && (!config.enabled || _blocked(service)))
                  ? null
                  : () => widget.movies
                        ? _previewOffer(service)
                        : _prepare(service),
              child: Text(
                widget.movies
                    ? 'View ticket details'
                    : 'Review ${service.id == 'phone' ? 'phone top-up' : '${service.id} bill'}',
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 12),
        SectionTitle(
          widget.movies
              ? 'Recent movie sandbox payments'
              : 'Recent sandbox payments',
          trailing: recent.isEmpty
              ? null
              : const Text(
                  'Tap to check status',
                  style: TextStyle(color: NeneColors.muted, fontSize: 12),
                ),
        ),
        if (recent.isEmpty && !_busy)
          _EmptyState(
            icon: Icons.history_rounded,
            title: 'No sandbox payments yet.',
            text: widget.movies
                ? 'Ticket checkouts you start appear here with their status.'
                : 'Checkouts you start appear here with their status.',
          )
        else if (recent.isNotEmpty)
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (index, order) in recent.indexed) ...[
                  if (index > 0) const Divider(indent: 72),
                  _HistoryRow(
                    order: order,
                    onTap: _busy ? null : () => _check(order.id),
                  ),
                ],
              ],
            ),
          ),
      ],
      const SizedBox(height: 12),
      Center(
        child: TextButton.icon(
          onPressed: _busy ? null : () => _run(_load),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Refresh services & payments'),
        ),
      ),
    ];
  }

  bool _blocked(PaymentServiceOffer service) => _recent.any(
    (order) =>
        order.service.id == service.id &&
        (order.state == 'awaiting_payment' ||
            (const {'electricity', 'water'}.contains(service.id) &&
                order.state == 'paid')),
  );

  List<Widget> _previewView(BuildContext context) {
    final preview = _preview!;
    return [
      Text('Ticket details', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 16),
      _Summary(
        service: preview.service,
        rows: [
          const _Row('Tickets', '1 fictional ticket'),
          _Row(
            'Price',
            '${_money(preview.service.amountMinor)} VND',
            emphasized: true,
          ),
          ..._checkoutRows,
        ],
      ),
      const SizedBox(height: 16),
      const NeneBanner(
        icon: Icons.visibility_outlined,
        title: 'Preview only',
        body:
            'Viewing these details creates no order and reserves no ticket or seat. The offer contains one fictional ticket.',
      ),
      const SizedBox(height: 16),
      if (!preview.checkoutAvailable)
        const _Note(
          icon: Icons.hourglass_top_rounded,
          text:
              'Sandbox checkout is not configured yet. You can explore the offers; no payment can be started.',
        )
      else if (_blocked(preview.service))
        const _Note(
          icon: Icons.schedule_rounded,
          warning: true,
          text:
              'An existing checkout is still pending. Return to recent payments and check its status before starting another.',
        )
      else
        const _Note(
          icon: Icons.lock_outline_rounded,
          text:
              'Continue to review the exact offer and authorize sandbox checkout with your authenticator. No real ticket will be issued.',
        ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed:
            _busy || !preview.checkoutAvailable || _blocked(preview.service)
            ? null
            : () => _prepare(preview.service),
        child: const Text('Continue to secure checkout'),
      ),
      const SizedBox(height: 4),
      TextButton(
        onPressed: _busy ? null : _catalog,
        child: const Text('Back to movie offers'),
      ),
    ];
  }

  List<Widget> _reviewView(BuildContext context) {
    final review = _review!;
    return [
      Text(
        'Review sandbox checkout',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 16),
      _Summary(
        service: review.service,
        rows: [
          _Row(
            review.service.isMovie ? 'Price' : 'Amount',
            '${_money(review.service.amountMinor)} VND',
            emphasized: true,
          ),
          ..._checkoutRows,
        ],
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const _IconBox(Icons.lock_outline_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Confirm with your authenticator',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'Your authenticator authorizes this exact service and amount. VNPay test-bank verification is a separate step.',
                style: TextStyle(color: NeneColors.muted, fontSize: 13.5),
              ),
              if (_expired) ...[
                const SizedBox(height: 16),
                const _Note(
                  icon: Icons.timer_off_outlined,
                  warning: true,
                  text:
                      'This review expired. Return to services for a fresh review.',
                ),
              ] else if (!_attempted) ...[
                const SizedBox(height: 18),
                TextField(
                  controller: _code,
                  enabled: !_busy && !_hidden,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 10,
                    fontFeatures: neneTabularFigures,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Authenticator code',
                    helperText: 'Six digits from your authenticator app',
                    counterText: '',
                  ),
                  onSubmitted: (_) {
                    if (!_busy) unawaited(_confirm());
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      if (!_expired && !_attempted) ...[
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy || _hidden ? null : _confirm,
          child: const Text('Confirm sandbox checkout'),
        ),
      ],
      if (!_attempted) ...[
        const SizedBox(height: 4),
        TextButton(
          onPressed: _busy ? null : _catalog,
          child: const Text('Back to demo services'),
        ),
      ],
    ];
  }

  List<Widget> _statusView(BuildContext context) {
    final status = _status!;
    final order = status.order;
    final canOpen =
        status.checkoutUrl != null &&
        order != null &&
        order.expiresAt.isAfter(DateTime.now());
    final reference = _requestId == null
        ? null
        : _Row.custom(
            'Sandbox reference',
            SelectableText(
              _requestId!,
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 13, color: NeneColors.ink),
            ),
          );
    return [
      _StatusHeader(
        state: status.state,
        title: _label(status.state),
        text: switch (status.state) {
          'paid' =>
            (order?.service.isMovie ?? widget.movies)
                ? 'VNPay confirmed a successful sandbox payment. No real ticket, seat reservation or cinema admission was issued.'
                : 'VNPay confirmed a successful sandbox payment. Service fulfillment is unavailable: this did not settle a bill or deliver phone credit.',
          'failed' =>
            'VNPay reported that this sandbox payment failed. No service was fulfilled.',
          'awaiting_payment' =>
            'Keep Nene open while using the sandbox. After returning, check status here. A browser redirect alone does not confirm payment.',
          'rejected' =>
            'This checkout was not authorized. Check status before reviewing it again.',
          _ =>
            'The outcome is not yet confirmed. Check status before starting another checkout. If your session ended, sign in again and inspect recent payments.',
        },
      ),
      const SizedBox(height: 16),
      if (order != null)
        _Summary(
          service: order.service,
          rows: [
            _Row(
              order.service.isMovie ? 'Price' : 'Amount',
              '${_money(order.service.amountMinor)} VND',
              emphasized: true,
            ),
            ..._checkoutRows,
            ?reference,
          ],
        )
      else if (reference != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: reference,
          ),
        ),
      if (status.state == 'awaiting_payment') ...[
        const SizedBox(height: 16),
        if (canOpen)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: NeneColors.pale,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _IconBox(
                      Icons.open_in_new_rounded,
                      background: Colors.white,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Continue to VNPay sandbox',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Opens in a separate tab. Only use VNPay test payment details, then come back here to check the status.',
                            style: TextStyle(
                              color: NeneColors.muted,
                              fontSize: 13.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _open,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open VNPay sandbox'),
                ),
              ],
            ),
          )
        else
          const _Note(
            icon: Icons.link_off_rounded,
            warning: true,
            text:
                'The checkout link is unavailable or expired. Check payment status; an expired link is not proof of payment failure.',
          ),
      ],
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: _busy || _requestId == null
            ? null
            : () => _check(_requestId!),
        icon: const Icon(Icons.refresh),
        label: const Text('Check payment status'),
      ),
      if (!{'unknown', 'checking'}.contains(status.state)) ...[
        const SizedBox(height: 4),
        TextButton(
          onPressed: _busy ? null : _catalog,
          child: const Text('Back to demo services'),
        ),
      ],
    ];
  }
}

String _label(String state) => switch (state) {
  'paid' => 'Sandbox payment successful',
  'failed' => 'Sandbox payment failed',
  'awaiting_payment' => 'Waiting for sandbox payment',
  'rejected' => 'Confirmation not accepted',
  _ => 'Confirmation outcome unknown',
};
String _money(String value) =>
    value.replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

String _when(DateTime time) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.day} ${months[local.month - 1]} ${local.year}, '
      '${two(local.hour)}:${two(local.minute)}';
}

/// Checkout facts shared by every summary: VNPay sandbox, Nene untouched.
const _checkoutRows = [
  _Row('Checkout', 'VNPay sandbox'),
  _Row('Nene account', 'No debit'),
];

const _warning = Color(0xFF8A4B14);
const _dangerSoft = Color(0xFFFBEBEA);
const _positiveSoft = Color(0xFFE3F3EA);

final _tonalButton = OutlinedButton.styleFrom(
  minimumSize: const Size.fromHeight(48),
  backgroundColor: NeneColors.pale,
  foregroundColor: NeneColors.action,
  disabledBackgroundColor: NeneColors.line,
  disabledForegroundColor: NeneColors.muted,
  side: BorderSide.none,
);

IconData _serviceIcon(PaymentServiceOffer service) => switch (service.id) {
  'electricity' => Icons.bolt_rounded,
  'water' => Icons.water_drop_outlined,
  'phone' => Icons.phone_iphone_rounded,
  'movie_evening_v1' => Icons.nightlight_outlined,
  _ => Icons.wb_sunny_outlined,
};

String _shortName(PaymentServiceOffer service) => switch (service.id) {
  'electricity' => 'Electricity',
  'water' => 'Water',
  'phone' => 'Phone top-up',
  _ => service.name,
};

/// Generic, truthful provider line: every biller and cinema is fictional.
String _providerLine(PaymentServiceOffer service) => switch (service.id) {
  'electricity' => 'Fictional power provider',
  'water' => 'Fictional water provider',
  'phone' => 'Fictional mobile carrier',
  'movie_matinee_v1' => 'Matinee session · fictional cinema',
  'movie_evening_v1' => 'Evening session · fictional cinema',
  _ => 'Fictional service',
};

String _amountLabel(PaymentServiceOffer service) => switch (service.id) {
  'phone' => 'Top-up amount',
  'electricity' || 'water' => 'Amount due',
  _ => 'Ticket price',
};

/// Colors for one service icon: evening offers read as a night ticket.
(Color, Color) _serviceColors(PaymentServiceOffer service) =>
    switch (service.id) {
      'movie_matinee_v1' => (NeneColors.apricotSoft, _warning),
      'movie_evening_v1' => (NeneColors.deep, NeneColors.apricot),
      _ => (NeneColors.pale, NeneColors.action),
    };

typedef _Tone = ({String chip, IconData icon, Color fg, Color bg});

_Tone _tone(BuildContext context, String state) {
  final danger = Theme.of(context).colorScheme.error;
  return switch (state) {
    'paid' => (
      chip: 'Paid',
      icon: Icons.check_circle_rounded,
      fg: NeneColors.positive,
      bg: _positiveSoft,
    ),
    'failed' => (
      chip: 'Failed',
      icon: Icons.cancel_rounded,
      fg: danger,
      bg: _dangerSoft,
    ),
    'awaiting_payment' => (
      chip: 'Pending',
      icon: Icons.schedule_rounded,
      fg: _warning,
      bg: NeneColors.apricotSoft,
    ),
    'rejected' => (
      chip: 'Not accepted',
      icon: Icons.block_rounded,
      fg: danger,
      bg: _dangerSoft,
    ),
    'checking' => (
      chip: 'Checking',
      icon: Icons.sync_rounded,
      fg: NeneColors.muted,
      bg: NeneColors.line,
    ),
    _ => (
      chip: 'Unknown',
      icon: Icons.help_outline_rounded,
      fg: NeneColors.muted,
      bg: NeneColors.line,
    ),
  };
}

class _StateChip extends StatelessWidget {
  const _StateChip(this.state);
  final String state;

  @override
  Widget build(BuildContext context) {
    final tone = _tone(context, state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        tone.chip,
        style: TextStyle(
          color: tone.fg,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _IconBox extends StatelessWidget {
  const _IconBox(
    this.icon, {
    this.size = 44,
    this.background = NeneColors.pale,
    this.color = NeneColors.action,
  });
  final IconData icon;
  final double size;
  final Color background, color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(size * .32),
    ),
    child: Icon(icon, color: color, size: size * .5),
  );
}

class _ServiceIcon extends StatelessWidget {
  const _ServiceIcon(this.service, {this.size = 44});
  final PaymentServiceOffer service;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (background, color) = _serviceColors(service);
    return _IconBox(
      _serviceIcon(service),
      size: size,
      background: background,
      color: color,
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    required this.service,
    required this.selected,
    required this.onTap,
  });
  final PaymentServiceOffer service;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: selected ? NeneColors.pale : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: selected ? NeneColors.action : NeneColors.line,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 14, 6, 12),
          child: Column(
            children: [
              _IconBox(
                _serviceIcon(service),
                background: selected ? NeneColors.action : NeneColors.pale,
                color: selected ? Colors.white : NeneColors.action,
              ),
              const SizedBox(height: 8),
              Text(
                _shortName(service),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: selected ? NeneColors.action : NeneColors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// One catalog card: a bill/top-up, or a movie offer with a ticket band.
class _OfferCard extends StatelessWidget {
  const _OfferCard({
    super.key,
    required this.service,
    required this.highlighted,
    required this.blocked,
    required this.action,
  });
  final PaymentServiceOffer service;
  final bool highlighted, blocked;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final movie = service.isMovie;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: highlighted ? NeneColors.action : NeneColors.line,
          width: highlighted ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (movie) _TicketBand(service),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (movie)
                  Text(
                    service.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  )
                else
                  _ServiceHeader(service),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: NeneColors.ivory,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _amountLabel(service),
                        style: const TextStyle(
                          color: NeneColors.muted,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${_money(service.amountMinor)} VND',
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                            fontFeatures: neneTabularFigures,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  service.description,
                  style: const TextStyle(color: NeneColors.muted, fontSize: 13),
                ),
                if (blocked) ...[
                  const SizedBox(height: 12),
                  const _Note(
                    icon: Icons.info_outline_rounded,
                    warning: true,
                    text:
                        'Check the existing payment below. A pending checkout or paid demo bill cannot be repeated.',
                  ),
                ],
                const SizedBox(height: 16),
                action,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Colored header band that makes a movie offer read like a ticket.
class _TicketBand extends StatelessWidget {
  const _TicketBand(this.service);
  final PaymentServiceOffer service;

  @override
  Widget build(BuildContext context) {
    final (background, accent) = _serviceColors(service);
    final evening = service.id == 'movie_evening_v1';
    final text = evening ? Colors.white : NeneColors.ink;
    return Container(
      color: background,
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: evening
                  ? Colors.white.withValues(alpha: .14)
                  : Colors.white.withValues(alpha: .75),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(_serviceIcon(service), color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  evening ? 'Evening session' : 'Matinee session',
                  style: TextStyle(
                    color: text,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Fictional cinema · 1 ticket',
                  style: TextStyle(
                    color: evening
                        ? Colors.white.withValues(alpha: .8)
                        : NeneColors.muted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.local_movies_outlined,
            size: 40,
            color: accent.withValues(alpha: .35),
          ),
        ],
      ),
    );
  }
}

class _ServiceHeader extends StatelessWidget {
  const _ServiceHeader(this.service);
  final PaymentServiceOffer service;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _ServiceIcon(service),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(service.name, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              _providerLine(service),
              style: const TextStyle(color: NeneColors.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    ],
  );
}

/// Review/status summary: service header, label/value rows, description.
class _Summary extends StatelessWidget {
  const _Summary({required this.service, required this.rows});
  final PaymentServiceOffer service;
  final List<_Row> rows;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ServiceHeader(service),
          const Padding(
            padding: EdgeInsets.only(top: 16, bottom: 6),
            child: Divider(),
          ),
          ...rows,
          const SizedBox(height: 8),
          Text(
            service.description,
            style: const TextStyle(color: NeneColors.muted, fontSize: 13),
          ),
        ],
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.emphasized = false}) : child = null;
  const _Row.custom(this.label, Widget this.child)
    : value = null,
      emphasized = false;
  final String label;
  final String? value;
  final Widget? child;
  final bool emphasized;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Text(label, style: const TextStyle(color: NeneColors.muted)),
        const SizedBox(width: 16),
        Expanded(
          child:
              child ??
              Text(
                value!,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontWeight: emphasized ? FontWeight.w700 : FontWeight.w600,
                  fontSize: emphasized ? 18 : 14,
                  fontFeatures: neneTabularFigures,
                ),
              ),
        ),
      ],
    ),
  );
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({
    required this.state,
    required this.title,
    required this.text,
  });
  final String state, title, text;

  @override
  Widget build(BuildContext context) {
    final tone = _tone(context, state);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: tone.bg, shape: BoxShape.circle),
              child: Icon(tone.icon, color: tone.fg, size: 34),
            ),
            const SizedBox(height: 14),
            _StateChip(state),
            const SizedBox(height: 10),
            Semantics(
              liveRegion: true,
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: NeneColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.order, required this.onTap});
  final PaymentOrder order;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          _ServiceIcon(order.service, size: 42),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        order.service.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StateChip(order.state),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _when(order.createdAt),
                        style: const TextStyle(
                          color: NeneColors.muted,
                          fontSize: 12.5,
                          fontFeatures: neneTabularFigures,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_money(order.service.amountMinor)} VND',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontFeatures: neneTabularFigures,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'How sandbox checkout works',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 14),
          for (final (index, step) in const [
            'Review a service and its amount',
            'Confirm with your Nene authenticator',
            'Open VNPay in a separate tab',
          ].indexed) ...[
            if (index > 0) const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: NeneColors.pale,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      color: NeneColors.action,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(step)),
              ],
            ),
          ],
          const SizedBox(height: 14),
          const Text(
            'An accepted, unexpired reference photo is required. Only use VNPay test payment details.',
            style: TextStyle(color: NeneColors.muted, fontSize: 13),
          ),
        ],
      ),
    ),
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.text,
  });
  final IconData icon;
  final String title, text;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconBox(
            icon,
            background: NeneColors.apricotSoft,
            color: NeneColors.deep,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: const TextStyle(
                    color: NeneColors.muted,
                    fontSize: 13.5,
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.text,
  });
  final IconData icon;
  final String title, text;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        children: [
          _IconBox(icon, size: 48),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: NeneColors.muted, fontSize: 13),
          ),
        ],
      ),
    ),
  );
}

/// Small inline note; warning notes use the apricot tint.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.warning = false});
  final IconData icon;
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: warning ? NeneColors.apricotSoft : NeneColors.pale,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: warning ? _warning : NeneColors.action),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5))),
      ],
    ),
  );
}

class _Alert extends StatelessWidget {
  const _Alert(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final danger = Theme.of(context).colorScheme.error;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _dangerSoft,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 20, color: danger),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5))),
          ],
        ),
      ),
    );
  }
}
