import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/payments_api.dart';
import '../data/session_owner.dart';
import 'customer_workspace.dart' show WorkspaceContent;
import 'nene_brand.dart';

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

  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      Text(
        widget.movies ? 'Movie tickets demo' : 'Bills & phone demo',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 12),
      _Notice(
        widget.movies
            ? 'Fictional cinema · sandbox only'
            : 'Fictional services · sandbox only',
        widget.movies
            ? 'Explore two fictional one-ticket offers. No real showing, seat reservation or admission is provided. Your Nene balance is unchanged.'
            : 'Try electricity, water and phone checkout with test data. No real bill is settled, no phone credit is delivered and your Nene balance is unchanged.',
      ),
      const SizedBox(height: 20),
      if (_busy)
        const LinearProgressIndicator(semanticsLabel: 'Loading payments'),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Semantics(liveRegion: true, child: Text(_error!)),
        const SizedBox(height: 12),
      ],
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
    if (widget.initialService != null) {
      services.sort(
        (a, b) => (a.id == widget.initialService ? 0 : 1).compareTo(
          b.id == widget.initialService ? 0 : 1,
        ),
      );
    }
    return [
      if (config != null && !config.enabled) ...[
        const _Notice(
          'Sandbox setup pending',
          'The demo catalog is ready. Checkout stays disabled until the project team configures VNPay sandbox credentials and a verified callback address.',
        ),
        const SizedBox(height: 16),
      ],
      if (config != null && config.enabled) ...[
        const Text(
          'Review a service, confirm with your Nene authenticator, then open VNPay in a separate tab. An accepted, unexpired reference photo is required. Only use VNPay test payment details.',
        ),
        const SizedBox(height: 16),
      ],
      for (final service in services) ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(switch (service.id) {
                      'electricity' => Icons.bolt_outlined,
                      'water' => Icons.water_drop_outlined,
                      'phone' => Icons.phone_android_outlined,
                      _ => Icons.movie_outlined,
                    }, color: NeneColors.action),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        service.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '${_money(service.amountMinor)} VND',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  service.description,
                  style: const TextStyle(color: NeneColors.muted),
                ),
                const SizedBox(height: 16),
                if (_blocked(service))
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Check the existing payment below. A pending checkout or paid demo bill cannot be repeated.',
                    ),
                  ),
                OutlinedButton(
                  onPressed:
                      _busy ||
                          (!widget.movies &&
                              (config?.enabled != true || _blocked(service)))
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
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
      Text(
        widget.movies
            ? 'Recent movie sandbox payments'
            : 'Recent sandbox payments',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      if (recent.isEmpty && !_busy) const Text('No sandbox payments yet.'),
      for (final order in recent)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            '${order.service.name} · ${_money(order.service.amountMinor)} VND',
          ),
          subtitle: Text(_label(order.state)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : () => _check(order.id),
        ),
      const SizedBox(height: 12),
      TextButton.icon(
        onPressed: _busy ? null : () => _run(_load),
        icon: const Icon(Icons.refresh),
        label: const Text('Refresh services & payments'),
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
      _Details(service: preview.service),
      const SizedBox(height: 16),
      const _Notice(
        'Preview only',
        'Viewing these details creates no order and reserves no ticket or seat. The offer contains one fictional ticket.',
      ),
      const SizedBox(height: 16),
      if (!preview.checkoutAvailable)
        const Text(
          'Sandbox checkout is not configured yet. You can explore the offers; no payment can be started.',
        )
      else if (_blocked(preview.service))
        const Text(
          'An existing checkout is still pending. Return to recent payments and check its status before starting another.',
        )
      else ...[
        const Text(
          'Continue to review the exact offer and authorize sandbox checkout with your authenticator. No real ticket will be issued.',
        ),
        const SizedBox(height: 12),
      ],
      FilledButton(
        onPressed:
            _busy || !preview.checkoutAvailable || _blocked(preview.service)
            ? null
            : () => _prepare(preview.service),
        child: const Text('Continue to secure checkout'),
      ),
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
      _Details(service: review.service),
      const SizedBox(height: 16),
      const Text(
        'Your authenticator authorizes this exact service and amount. VNPay test-bank verification is a separate step.',
      ),
      const SizedBox(height: 16),
      if (_expired)
        const Text(
          'This review expired. Return to services for a fresh review.',
        )
      else if (!_attempted) ...[
        TextField(
          controller: _code,
          enabled: !_busy && !_hidden,
          keyboardType: TextInputType.number,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Authenticator code',
            helperText: 'Six digits from your authenticator app',
          ),
          onSubmitted: (_) {
            if (!_busy) unawaited(_confirm());
          },
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy || _hidden ? null : _confirm,
          child: const Text('Confirm sandbox checkout'),
        ),
      ],
      if (!_attempted)
        TextButton(
          onPressed: _busy ? null : _catalog,
          child: const Text('Back to demo services'),
        ),
    ];
  }

  List<Widget> _statusView(BuildContext context) {
    final status = _status!;
    final order = status.order;
    final canOpen =
        status.checkoutUrl != null &&
        order != null &&
        order.expiresAt.isAfter(DateTime.now());
    return [
      const SizedBox(height: 12),
      Semantics(
        liveRegion: true,
        child: Text(
          _label(status.state),
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      const SizedBox(height: 12),
      Text(switch (status.state) {
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
      }),
      const SizedBox(height: 16),
      if (order != null) _Details(service: order.service),
      if (_requestId != null) ...[
        const SizedBox(height: 16),
        const Text(
          'Sandbox reference',
          style: TextStyle(color: NeneColors.muted),
        ),
        SelectableText(_requestId!),
      ],
      if (status.state == 'awaiting_payment') ...[
        const SizedBox(height: 16),
        if (canOpen)
          FilledButton.icon(
            onPressed: _busy ? null : _open,
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open VNPay sandbox'),
          )
        else
          const Text(
            'The checkout link is unavailable or expired. Check payment status; an expired link is not proof of payment failure.',
          ),
      ],
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _busy || _requestId == null
            ? null
            : () => _check(_requestId!),
        icon: const Icon(Icons.refresh),
        label: const Text('Check payment status'),
      ),
      if (!{'unknown', 'checking'}.contains(status.state))
        TextButton(
          onPressed: _busy ? null : _catalog,
          child: const Text('Back to demo services'),
        ),
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

class _Details extends StatelessWidget {
  const _Details({required this.service});
  final PaymentServiceOffer service;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(service.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '${_money(service.amountMinor)} VND',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(service.description),
          const SizedBox(height: 12),
          const Text(
            'VNPay sandbox checkout · no Nene account debit',
            style: TextStyle(color: NeneColors.muted),
          ),
        ],
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.title, this.text);
  final String title, text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: NeneColors.pale,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(text),
      ],
    ),
  );
}
