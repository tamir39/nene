import 'dart:async';
import 'package:flutter/material.dart';
import '../data/banking_repository.dart';
import '../data/confirmation_api.dart';
import '../data/face_check.dart';
import '../data/reference_photo_source.dart';
import '../data/session_owner.dart';
import 'customer_workspace.dart' show WorkspaceContent;
import 'nene_brand.dart';
import 'nene_components.dart' show SectionTitle;

/// Largest single same-bank or other-bank transfer the backend accepts.
final maximumTransferMinor = BigInt.from(50000000);

/// Failed face checks the server allows for one review.
const maximumFaceCheckFailures = 5;

class ConfirmationScreen extends StatefulWidget {
  const ConfirmationScreen({
    super.key,
    required this.account,
    required this.api,
    this.photos,
    this.liveness,
  });
  final BankAccount account;
  final ConfirmationApi api;

  /// Front-camera selfies for a face check; the device camera by default.
  final ReferencePhotoSource? photos;

  /// On-device pose checks; ML Kit on Android, unavailable on web/desktop.
  final LivenessCheck? liveness;
  @override
  State<ConfirmationScreen> createState() => _ConfirmationScreenState();
}

class _ConfirmationScreenState extends State<ConfirmationScreen>
    with WidgetsBindingObserver {
  final _destination = TextEditingController(),
      _amount = TextEditingController(),
      _code = TextEditingController();
  Map<String, dynamic>? _review;
  String? _state, _error;
  bool _busy = false, _hidden = false;
  Timer? _expiry;
  bool _enabled = false;
  List<Map<String, dynamic>> _recent = [];
  List<Map<String, dynamic>> _banks = [];
  String? _bankCode, _recipient;

  /// Set when confirm answered 409 FACE_CHECK_REQUIRED for this review.
  bool _faceDemanded = false;
  String? _faceCheckId, _faceNotice;
  Timer? _faceExpiry;
  bool _faceBusy = false;

  /// Changing it starts the face step again with fresh photos.
  int _faceAttempt = 0;
  late final ReferencePhotoSource _photos =
      widget.photos ?? DeviceReferencePhotoSource();
  late final LivenessCheck _liveness =
      widget.liveness ?? createDeviceLivenessCheck();
  bool get _transfer => _send && !_cash;
  bool get _faceRequired =>
      _transfer && (_review?['faceCheckRequired'] == true || _faceDemanded);
  bool get _locked => _busy || (_faceBusy && _state == 'review');
  bool get _interbank => widget.api.interbank;
  bool get _hasReviewToken => _review?['reviewToken'] is String;
  Map<String, dynamic>? get _bank =>
      _banks.where((bank) => bank['code'] == _bankCode).firstOrNull;
  bool get _send => widget.api.sendMoney;
  bool get _cash => widget.api.cashOperation != null;
  bool get _deposit => widget.api.cashOperation == CashOperation.deposit;
  String? _cashBalance;
  String get _noun =>
      _cash ? (_deposit ? 'Deposit' : 'Withdrawal') : 'Transfer';
  String get _confirmLabel => _cash
      ? (_deposit ? 'Confirm demo deposit' : 'Confirm demo withdrawal')
      : _interbank
      ? 'Confirm simulated transfer'
      : 'Confirm and send demo funds';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_send) _run(_loadRecent);
  }

  Future<void> _loadRecent() async {
    final config = await widget.api.configuration();
    final data = await widget.api.recent();
    if (mounted) {
      setState(() {
        _enabled = config['enabled'] == true;
        _cashBalance = config['cashBalanceMinor'] as String?;
        if (_interbank) {
          _banks = (config['banks'] as List).cast<Map<String, dynamic>>();
          if (!_banks.any((bank) => bank['code'] == _bankCode)) {
            _bankCode = null;
            _recipient = null;
          }
        }
        _recent = (data[_cash ? 'operations' : 'transfers'] as List)
            .cast<Map<String, dynamic>>();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiry?.cancel();
    _faceExpiry?.cancel();
    _destination.dispose();
    _amount.dispose();
    _code.dispose();
    _review = null;
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

  Future<void> _run(Future<void> Function() work) async {
    if (_locked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } on SessionMutationRejected {
      if (mounted) {
        setState(
          () => _error = _cash
              ? 'Check available funds, prepared demo accounts, an unexpired accepted reference and an amount below 5,000,000 VND. For a rejected code, check status before a new review; wait for a fresh code or 15 minutes after too many attempts.'
              : _send
              ? 'Check available funds, prepared demo accounts, an unexpired accepted reference and an amount up to 50,000,000 VND. For a rejected code, check status before a new review; wait for a fresh code or 15 minutes after too many attempts.'
              : 'Details or code were not accepted, or the code was already used. Check status, then start a new review with a fresh code. After too many attempts, wait 15 minutes.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _state = 'unknown';
          _code.clear();
          _error = _send
              ? _cash
                    ? 'Outcome is unconfirmed. Check recent operations or account history after signing in. Do not repeat the operation until the outcome is known.'
                    : 'Transfer outcome is unconfirmed. Check recent transfers or account history after signing in. Do not send it again until the outcome is known.'
              : 'Confirmation could not be checked. No money was sent. Sign in again if needed; do not repeat an uncertain request.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare() => _run(() async {
    final security = await widget.api.security.status();
    if (!mounted) return;
    if (security['state'] != 'ready') {
      setState(
        () => _error =
            'Finish authenticator setup or recovery in My profile → Transaction security before reviewing a transaction.',
      );
      return;
    }
    if ((_interbank && (_bankCode == null || _recipient == null)) ||
        (!_cash &&
            !_interbank &&
            !RegExp(r'^\d{12}$').hasMatch(_destination.text.trim())) ||
        !RegExp(r'^[1-9]\d{0,15}$').hasMatch(_amount.text.trim())) {
      setState(
        () => _error = _interbank
            ? 'Choose a fictional bank and demo recipient, then enter a positive whole VND amount.'
            : _cash
            ? 'Enter a positive whole VND amount.'
            : 'Enter a 12-digit Nene account number and a positive whole VND amount.',
      );
      return;
    }
    if (_transfer && BigInt.parse(_amount.text.trim()) > maximumTransferMinor) {
      setState(() => _error = 'Each transfer can be at most 50,000,000 VND.');
      return;
    }
    final data = await widget.api.review(
      widget.account.id,
      _interbank ? _recipient! : _destination.text.trim(),
      _amount.text.trim(),
      destinationBankCode: _bankCode,
    );
    if (!mounted) return;
    setState(() {
      _review = data;
      _state = 'review';
      _resetFace();
    });
    _expiry?.cancel();
    _expiry = Timer(
      DateTime.parse(data['expiresAt'] as String).difference(DateTime.now()),
      () {
        if (mounted) {
          setState(() {
            if (_state == 'posted' ||
                _state == 'unknown' ||
                _state == 'checking') {
              return;
            }
            _state = 'expired';
            _code.clear();
          });
        }
      },
    );
  });
  Future<void> _confirm() => _run(() async {
    final code = _code.text.trim();
    _code.clear();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter a six-digit authenticator code.');
      return;
    }
    // A review permits one submitted proof. Definite rejection needs a new review.
    setState(() => _state = 'checking');
    final Map<String, dynamic> data;
    try {
      data = await widget.api.confirm(
        _review!,
        code,
        faceCheckId: _faceCheckId,
      );
    } on FaceCheckRequired {
      // Rejected before posting: the same review continues with a face check.
      if (mounted) {
        setState(() {
          _state = 'review';
          _resetFace();
          _faceDemanded = true;
          _faceNotice =
              'Face check required. No money was sent. Complete the face check below, then enter a new authenticator code.';
        });
      }
      return;
    }
    if (data['state'] == 'posted') {
      _expiry?.cancel();
      _faceExpiry?.cancel();
    }
    if (mounted) setState(() => _state = data['state'] as String);
  });

  /// Forgets any face check; a later one needs new photos.
  void _resetFace() {
    _faceExpiry?.cancel();
    _faceDemanded = false;
    _faceCheckId = null;
    _faceNotice = null;
    _faceBusy = false;
    _faceAttempt++;
  }

  void _faceMatched(String id, DateTime expiresAt) {
    // The server enforces the expiry; the local timer only prompts early.
    // A skewed device clock falls back to the documented 5-minute window.
    var left = expiresAt.difference(DateTime.now());
    if (left <= Duration.zero || left > const Duration(minutes: 5)) {
      left = const Duration(minutes: 5);
    }
    setState(() {
      _faceCheckId = id;
      _faceNotice = null;
      _faceBusy = false;
    });
    _faceExpiry?.cancel();
    _faceExpiry = Timer(left, () {
      if (!mounted || _faceCheckId != id || _state != 'review') return;
      setState(() {
        final demanded = _faceDemanded;
        _resetFace();
        _faceDemanded = demanded;
        _code.clear();
        _faceNotice =
            'Your face check expired after 5 minutes. Take the face check again before entering a code.';
      });
    });
  }

  Future<void> _status() => _run(() async {
    final data = await widget.api.status(_review!['requestId'] as String);
    if (data['state'] == 'posted') _expiry?.cancel();
    if (mounted) {
      setState(() {
        _state = data['state'] as String;
        if (_interbank && data['receipt'] != null) {
          _review = {..._review!, ...data['receipt'] as Map<String, dynamic>};
        }
      });
    }
  });
  Future<void> _recover(String requestId) => _run(() async {
    final data = await widget.api.status(requestId);
    if (!mounted) return;
    setState(() {
      _expiry?.cancel();
      _review = {
        'requestId': requestId,
        if (data['receipt'] != null) ...data['receipt'] as Map<String, dynamic>,
      };
      _state = data['state'] as String;
      _resetFace();
      _code.clear();
    });
  });
  Future<void> _cancel() => _run(() async {
    final data = await widget.api.cancel(_review!['reviewToken'] as String);
    if (mounted) {
      setState(() {
        _state = data['state'] as String;
        _code.clear();
      });
    }
  });
  Future<void> _edit() => _run(() async {
    // Revoke the previous signed review before allowing edits or a new proof.
    await widget.api.cancel(_review!['reviewToken'] as String);
    if (mounted) {
      setState(() {
        _expiry?.cancel();
        _review = null;
        _state = null;
        _resetFace();
        _code.clear();
      });
    }
  });

  String get _title => _interbank
      ? 'Other-bank demo transfer'
      : _cash
      ? (_deposit ? 'Deposit demo funds' : 'Withdraw demo funds')
      : _send
      ? 'Transfer demo funds'
      : 'Transfer confirmation';

  String get _intro => _interbank
      ? 'Local simulation with fictional banks and test recipients. No real bank receives a payment. Confirmation changes your source demo balance and records simulated delivery. Each transfer can be up to 50,000,000 VND; large transfers also need a face check.'
      : _cash
      ? 'Local cash simulation only. Deposits move your limited simulated cash into this account; withdrawals move it back. No real cash or external payment is involved. Amounts of 5,000,000 VND or more are blocked.'
      : _send
      ? 'Synthetic local funds only. Sending changes both demo balances and records a transfer. Each transfer can be up to 50,000,000 VND; large transfers also need a face check.'
      : 'Confirmation preview only. No money will be sent. Identity checks and money movement are not available yet.';

  /// Every review and receipt carries an honest label for its kind of money.
  String get _modeLabel => _interbank
      ? 'Simulated · fictional bank'
      : _cash
      ? 'Simulated cash · demo'
      : _send
      ? 'Synthetic demo funds'
      : 'Preview · not sent';

  /// Groups whole-VND digits for display; anything unexpected is shown as received.
  String _money(Object? minor) =>
      minor is String && RegExp(r'^\d+$').hasMatch(minor)
      ? widget.account.amountLabel(minor)
      : '$minor VND';

  static String? _postedLabel(Object? value) {
    final posted = value is String ? DateTime.tryParse(value) : null;
    if (posted == null) return null;
    final time = posted.toUtc().add(const Duration(hours: 7));
    String pad(int part) => part.toString().padLeft(2, '0');
    return '${time.year}-${pad(time.month)}-${pad(time.day)} '
        '${pad(time.hour)}:${pad(time.minute)} (UTC+07)';
  }

  String get _stateMessage => switch (_state) {
    'posted' =>
      _interbank
          ? 'Simulated delivery recorded. Your source demo balance and transaction history were updated. No real bank received a payment.'
          : _cash
          ? 'Demo ${_noun.toLowerCase()} completed. Account balance and history were updated. No real cash moved.'
          : 'Demo transfer sent. Balances and transaction history were updated.',
    'factor_confirmed' =>
      'Authenticator checked for these details. Transfer not sent.',
    'cancelled' =>
      _cash
          ? 'Confirmation cancelled. No deposit or withdrawal was posted.'
          : 'Confirmation cancelled. Transfer not sent.',
    'rejected' => 'Code not accepted. Start a new review with a fresh code.',
    'expired' =>
      _send
          ? 'Review expired. Check recent operations or history for any submitted transaction.'
          : 'Review or confirmation expired. Transfer not sent.',
    'invalidated' =>
      'Security or sign-in changed. This confirmation is no longer valid.',
    'checking' =>
      'Confirmation not yet established. Check status before continuing.',
    _ =>
      _send
          ? _cash
                ? 'Outcome unconfirmed. Check recent operations/history before trying again.'
                : 'Transfer outcome unconfirmed. Check recent transfers/history before sending again.'
          : 'Confirmation uncertain. No money was sent.',
  };

  ({IconData icon, _Tone tone, String title}) get _stateLook =>
      switch (_state) {
        'posted' => (
          icon: Icons.check_rounded,
          tone: _Tone.success,
          title: _interbank
              ? 'Simulated transfer complete'
              : _cash
              ? 'Demo ${_noun.toLowerCase()} complete'
              : 'Demo transfer successful',
        ),
        'factor_confirmed' => (
          icon: Icons.verified_user_outlined,
          tone: _Tone.info,
          title: 'Authenticator verified',
        ),
        'cancelled' => (
          icon: Icons.close_rounded,
          tone: _Tone.neutral,
          title: 'Cancelled',
        ),
        'rejected' => (
          icon: Icons.error_outline_rounded,
          tone: _Tone.error,
          title: 'Not confirmed',
        ),
        'expired' => (
          icon: Icons.timer_off_outlined,
          tone: _Tone.warning,
          title: 'Time limit reached',
        ),
        'invalidated' => (
          icon: Icons.gpp_maybe_outlined,
          tone: _Tone.warning,
          title: 'No longer valid',
        ),
        'checking' => (
          icon: Icons.hourglass_top_rounded,
          tone: _Tone.info,
          title: 'Status pending',
        ),
        _ => (
          icon: Icons.help_outline_rounded,
          tone: _Tone.warning,
          title: 'Status unknown',
        ),
      };

  @override
  Widget build(BuildContext context) => WorkspaceContent(
    children: [
      Text(_title, style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      _Note(
        icon: _send ? Icons.science_outlined : Icons.visibility_outlined,
        text: _intro,
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 4,
        child: _busy
            ? ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: const LinearProgressIndicator(
                  semanticsLabel: 'Checking confirmation',
                ),
              )
            : null,
      ),
      const SizedBox(height: 12),
      if (_error != null) ...[
        _Alert(_error!, tone: _Tone.error),
        const SizedBox(height: 16),
      ],
      if (_review == null) ..._form() else ..._reviewed(),
    ],
  );

  List<Widget> _form() => [
    if (_send && !_enabled && !_busy) ...[
      _Panel(
        children: [
          _StatusHeader(
            icon: Icons.block_rounded,
            tone: _Tone.warning,
            title: 'Demo unavailable',
            message: _cash
                ? 'This local cash demo is not enabled. Ask the project team to prepare the demo account.'
                : 'This local transfer demo is not enabled. Ask the project team to prepare the demo accounts.',
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: () => _run(_loadRecent),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Check again'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
    ],
    _SourceCard(
      label: _cash ? (_deposit ? 'Deposit to' : 'Withdraw from') : 'From',
      account: widget.account,
    ),
    if (_cash) ...[
      const SizedBox(height: 10),
      _Note(
        icon: Icons.payments_outlined,
        text:
            'Simulated cash outside accounts: ${_cashBalance == null ? 'not prepared' : _money(_cashBalance)}',
      ),
    ],
    if (_interbank) ...[
      const SizedBox(height: 20),
      const SectionTitle('Recipient'),
      DropdownButtonFormField<String>(
        initialValue: _bankCode,
        isExpanded: true,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 15),
        decoration: const InputDecoration(labelText: 'Fictional bank'),
        items: _banks
            .map(
              (bank) => DropdownMenuItem(
                value: bank['code'] as String,
                child: Text(bank['name'] as String),
              ),
            )
            .toList(),
        onChanged: _busy
            ? null
            : (value) => setState(() {
                _bankCode = value;
                _recipient = null;
              }),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: ValueKey(_bankCode),
        initialValue: _recipient,
        isExpanded: true,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 15),
        decoration: const InputDecoration(labelText: 'Demo recipient'),
        items: ((_bank?['recipients'] as List?) ?? [])
            .map(
              (recipient) => DropdownMenuItem(
                value: recipient['accountNumber'] as String,
                child: Text(
                  '${recipient['name']} · ${recipient['accountNumber']}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(),
        onChanged: _busy || _bank == null
            ? null
            : (value) => setState(() => _recipient = value),
      ),
    ],
    if (!_cash && !_interbank) ...[
      const SizedBox(height: 20),
      const SectionTitle('Recipient'),
      TextField(
        controller: _destination,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        maxLength: 12,
        style: const TextStyle(
          letterSpacing: .8,
          fontFeatures: neneTabularFigures,
        ),
        decoration: const InputDecoration(
          labelText: 'Recipient Nene account number',
          prefixIcon: Icon(Icons.person_outline_rounded),
        ),
      ),
    ],
    SizedBox(height: !_cash && !_interbank ? 8 : 20),
    const SectionTitle('Amount'),
    TextField(
      controller: _amount,
      enabled: !_busy,
      keyboardType: TextInputType.number,
      style: const TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        fontFeatures: neneTabularFigures,
      ),
      decoration: InputDecoration(
        labelText: 'Amount in VND',
        hintText: '0',
        suffixText: 'VND',
        suffixStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: NeneColors.muted,
        ),
        helperText: _cash
            ? 'Whole VND only · amounts of 5,000,000 VND or more are blocked'
            : _send
            ? 'Whole VND only · up to 50,000,000 VND. Over 10,000,000 VND, or over 20,000,000 VND in a day, needs a face check'
            : 'Whole VND only',
        helperMaxLines: 10,
      ),
    ),
    const SizedBox(height: 24),
    FilledButton(
      onPressed: _busy || _hidden || (_send && !_enabled) ? null : _prepare,
      child: const Text('Review confirmation'),
    ),
    if (_send) ..._recentSection(),
  ];

  List<Widget> _recentSection() => [
    const SizedBox(height: 28),
    SectionTitle(
      _cash
          ? 'Recent ${_noun.toLowerCase()} attempts'
          : 'Recent transfer attempts',
      trailing: IconButton(
        tooltip: _cash
            ? 'Refresh recent operations'
            : 'Refresh recent transfers',
        visualDensity: VisualDensity.compact,
        onPressed: _busy ? null : () => _run(_loadRecent),
        icon: const Icon(Icons.refresh_rounded),
      ),
    ),
    if (_recent.isEmpty)
      _Note(
        icon: Icons.history_rounded,
        text: _cash
            ? 'No recent ${_noun.toLowerCase()} attempts to show.'
            : 'No recent transfer attempts to show.',
      )
    else
      Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (final (index, item) in _recent.indexed) ...[
              if (index > 0) const Divider(),
              _recentTile(item),
            ],
          ],
        ),
      ),
  ];

  Widget _recentTile(Map<String, dynamic> item) {
    final posted = item['state'] == 'posted';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: _IconBadge(
        posted ? Icons.check_rounded : Icons.priority_high_rounded,
        tone: posted ? _Tone.success : _Tone.warning,
        size: 40,
      ),
      title: Text(
        posted
            ? '${_interbank
                  ? 'Simulated'
                  : _cash
                  ? (_deposit ? 'Deposited' : 'Withdrawn')
                  : 'Sent'} ${_money((item['receipt'] as Map)['amountMinor'])} · demo funds'
            : '${item['state']} · check before sending again',
        style: const TextStyle(
          fontSize: 14.5,
          fontWeight: FontWeight.w600,
          fontFeatures: neneTabularFigures,
        ),
      ),
      subtitle: Text(
        _interbank && item['receipt'] != null
            ? '${item['receipt']['destinationBankName']} · ${item['receipt']['destinationRecipientName']}\n${item['receipt']['destinationAccountNumber']}'
            : item['requestId'] as String,
        style: const TextStyle(
          color: NeneColors.muted,
          fontSize: 12,
          fontFeatures: neneTabularFigures,
        ),
      ),
      trailing: _interbank
          ? const Icon(Icons.chevron_right_rounded, color: NeneColors.muted)
          : null,
      onTap: _interbank && !_busy
          ? () => _recover(item['requestId'] as String)
          : null,
    );
  }

  List<Widget> _reviewed() {
    final review = _review!;
    final awaitingInput = _state == 'review' && _hasReviewToken;
    final awaitingFace = awaitingInput && _faceRequired && _faceCheckId == null;
    final awaitingCode = awaitingInput && !awaitingFace;
    final posted = _state == 'posted';
    final time = _postedLabel(review['postedAt']);
    final rows = <(String, String)>[
      if (review['requestId'] is String)
        ('Reference', review['requestId'] as String),
      if (time != null) ('Time', time),
      if (_cash) ...[
        (
          'From',
          _deposit ? 'Simulated cash' : 'Account ${review['accountNumber']}',
        ),
        (
          'To',
          _deposit ? 'Account ${review['accountNumber']}' : 'Simulated cash',
        ),
      ] else if (review['destinationAccountNumber'] != null) ...[
        if (review['sourceAccountNumber'] != null)
          ('From', '${review['sourceAccountNumber']}'),
        if (_interbank) ...[
          ('Fictional bank', '${review['destinationBankName']}'),
          ('Demo recipient', '${review['destinationRecipientName']}'),
        ],
        ('To', '${review['destinationAccountNumber']}'),
      ],
    ];
    final look = _stateLook;
    final restartLabel = !_hasReviewToken
        ? 'Back to recent transfers'
        : _cash
        ? 'Start another ${_noun.toLowerCase()}'
        : 'Start another transfer';
    final actions = <({String label, VoidCallback? onPressed})>[
      if (!awaitingInput)
        (label: 'Check confirmation status', onPressed: _busy ? null : _status),
      if (!posted && _hasReviewToken)
        (label: 'Edit details / new review', onPressed: _locked ? null : _edit),
      if (posted || !_hasReviewToken)
        (
          label: restartLabel,
          onPressed: _busy
              ? null
              : () => _run(() async {
                  setState(() {
                    _review = null;
                    _state = null;
                    _resetFace();
                  });
                  await _loadRecent();
                }),
        ),
      if (_state != 'cancelled' && !posted && _hasReviewToken)
        (label: 'Cancel confirmation', onPressed: _locked ? null : _cancel),
    ];
    // One emphasized next step per outcome; the others stay quiet.
    final primary = awaitingInput
        ? null
        : posted
        ? restartLabel
        : _hasReviewToken &&
              const {
                'rejected',
                'cancelled',
                'invalidated',
                'factor_confirmed',
              }.contains(_state)
        ? 'Edit details / new review'
        : 'Check confirmation status';
    return [
      _SummaryCard(
        header: awaitingInput
            ? null
            : _StatusHeader(
                icon: look.icon,
                tone: look.tone,
                title: look.title,
                message: _stateMessage,
              ),
        badge: _modeLabel,
        caption: '$_noun amount',
        amount: review['amountMinor'] == null
            ? null
            : _money(review['amountMinor']),
        note: _hasReviewToken
            ? (_send
                  ? 'Demo ${_noun.toLowerCase()} fee: 0 VND.'
                  : 'Preview fee: 0 VND. This is not a transfer quote.')
            : null,
        rows: rows,
      ),
      if (review['sufficientFunds'] == false) ...[
        const SizedBox(height: 12),
        const _Alert(
          'Insufficient funds for this amount. You can test the confirmation check, but this transfer cannot be sent.',
          tone: _Tone.warning,
        ),
      ],
      const SizedBox(height: 20),
      if (awaitingInput && _faceNotice != null) ...[
        _Alert(_faceNotice!, tone: _Tone.warning),
        const SizedBox(height: 16),
      ],
      if (awaitingFace) ...[
        _FaceStep(
          key: ValueKey(_faceAttempt),
          api: widget.api,
          reviewToken: review['reviewToken'] as String,
          photos: _photos,
          liveness: _liveness,
          enabled: !_busy,
          onBusy: (busy) {
            if (mounted) setState(() => _faceBusy = busy);
          },
          onMatched: _faceMatched,
        ),
        const SizedBox(height: 20),
      ],
      if (awaitingCode && _faceCheckId != null) ...[
        const _Note(
          icon: Icons.verified_user_outlined,
          text:
              'Face check passed for this transfer. Enter your authenticator code within 5 minutes.',
        ),
        const SizedBox(height: 16),
      ],
      if (awaitingCode) ...[
        _codeCard(),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy || _hidden ? null : _confirm,
          child: Text(
            _send ? _confirmLabel : 'Check authenticator · do not send',
          ),
        ),
      ],
      for (final action in actions)
        if (action.label == primary)
          FilledButton(onPressed: action.onPressed, child: Text(action.label)),
      const SizedBox(height: 8),
      for (final action in actions)
        if (action.label != primary)
          TextButton(onPressed: action.onPressed, child: Text(action.label)),
    ];
  }

  Widget _codeCard() => _Panel(
    children: [
      const Center(
        child: _IconBadge(
          Icons.lock_outline_rounded,
          tone: _Tone.info,
          size: 56,
          circle: true,
        ),
      ),
      const SizedBox(height: 14),
      Text(
        'Confirm with your authenticator',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 6),
      const Text(
        'Check the accounts and amount. Enter a fresh code from your registered authenticator. A recovery code cannot confirm this operation.',
        textAlign: TextAlign.center,
        style: TextStyle(color: NeneColors.muted, fontSize: 13.5),
      ),
      if (!_hidden) ...[
        const SizedBox(height: 18),
        TextField(
          controller: _code,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: 10,
            fontFeatures: neneTabularFigures,
          ),
          decoration: const InputDecoration(
            labelText: 'Authenticator code',
            floatingLabelBehavior: FloatingLabelBehavior.always,
            floatingLabelAlignment: FloatingLabelAlignment.center,
            hintText: '6-digit code',
            hintStyle: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w400,
              letterSpacing: 0,
              color: NeneColors.muted,
            ),
            filled: true,
            fillColor: NeneColors.pale,
          ),
        ),
      ],
    ],
  );
}

enum _FacePhase { straight, turned, sending, retry, resend, stopped }

/// Face check before a large transfer. On Android: photo 1 looking straight
/// with open eyes, photo 2 with the head turned, both checked on the device.
/// On web and desktop previews: one photo without device checks. Only photo
/// 1 is uploaded; the server compares it with the accepted reference photo.
class _FaceStep extends StatefulWidget {
  const _FaceStep({
    super.key,
    required this.api,
    required this.reviewToken,
    required this.photos,
    required this.liveness,
    required this.enabled,
    required this.onBusy,
    required this.onMatched,
  });
  final ConfirmationApi api;
  final String reviewToken;
  final ReferencePhotoSource photos;
  final LivenessCheck liveness;
  final bool enabled;
  final ValueChanged<bool> onBusy;
  final void Function(String faceCheckId, DateTime expiresAt) onMatched;

  @override
  State<_FaceStep> createState() => _FaceStepState();
}

class _FaceStepState extends State<_FaceStep> {
  _FacePhase _phase = _FacePhase.straight;
  ReferencePhoto? _selfie;
  String? _key, _message, _working;
  bool _blink = false, _turn = false;
  int _failures = 0;

  bool get _device => widget.liveness.available;

  void _busy(String? label) {
    if (!mounted) return;
    setState(() => _working = label);
    widget.onBusy(label != null);
  }

  Future<void> _take() async {
    if (_working != null || !widget.enabled) return;
    final pose = _phase == _FacePhase.turned
        ? LivenessPose.turned
        : LivenessPose.straight;
    setState(() {
      _message = null;
      if (pose == LivenessPose.straight) {
        _phase = _FacePhase.straight;
        _selfie = null;
        _key = null;
      }
    });
    _busy('Opening the camera…');
    try {
      final photo = await widget.photos.capture();
      if (!mounted || photo == null) return;
      if (!_device) {
        _selfie = photo;
        _blink = false;
        _turn = false;
        _key = newIdempotencyKey();
        await _send();
        return;
      }
      _busy(
        pose == LivenessPose.straight
            ? 'Checking photo 1…'
            : 'Checking photo 2…',
      );
      final result = await widget.liveness.check(pose, photo.bytes);
      if (!mounted) return;
      if (result != LivenessResult.passed) {
        setState(() => _message = _livenessMessage(result, pose));
        return;
      }
      if (pose == LivenessPose.straight) {
        setState(() {
          _selfie = photo;
          _phase = _FacePhase.turned;
        });
        return;
      }
      // Photo 2 only shows the head turned; it is neither uploaded nor kept.
      _blink = true;
      _turn = true;
      _key = newIdempotencyKey();
      await _send();
    } on PhotoCaptureException catch (failure) {
      if (mounted) setState(() => _message = failure.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'The camera is unavailable. Check camera access in device settings and try again.',
        );
      }
    } finally {
      _busy(null);
    }
  }

  Future<void> _resend() async {
    if (_working != null || !widget.enabled) return;
    setState(() => _message = null);
    try {
      await _send();
    } finally {
      _busy(null);
    }
  }

  /// Uploads photo 1. An unknown outcome keeps the photo and its
  /// Idempotency-Key, so "send again" repeats the exact same request.
  Future<void> _send() async {
    final selfie = _selfie, key = _key;
    if (selfie == null || key == null) return;
    setState(() => _phase = _FacePhase.sending);
    _busy('Comparing with your reference photo. This can take a few seconds…');
    final FaceCheckOutcome outcome;
    try {
      outcome = await widget.api.faceCheck(
        reviewToken: widget.reviewToken,
        selfie: selfie.bytes,
        contentType: selfie.contentType,
        blink: _blink,
        turn: _turn,
        idempotencyKey: key,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _selfie = null;
          _key = null;
          _phase = _FacePhase.stopped;
          _message =
              'Your sign-in changed during the face check. No money was sent. Sign in again before continuing.';
        });
      }
      return;
    }
    if (!mounted) return;
    final id = outcome.faceCheckId;
    if (id != null) {
      _selfie = null;
      _key = null;
      widget.onMatched(id, outcome.expiresAt!);
      return;
    }
    setState(() {
      final refusal = outcome.refusal, stop = outcome.stop;
      if (refusal == null && stop == null) {
        _phase = _FacePhase.resend;
        _message =
            'The face check did not finish. No money was sent. Check your connection, then send the same photo again.';
        return;
      }
      _selfie = null;
      _key = null;
      if (refusal != null) {
        _failures++;
        _phase = _failures >= maximumFaceCheckFailures
            ? _FacePhase.stopped
            : _FacePhase.retry;
        _message = _phase == _FacePhase.stopped
            ? 'Too many face checks did not pass for this review. No money was sent. Start a new review to try again.'
            : _refusalMessage(refusal);
      } else {
        _phase = _FacePhase.stopped;
        _message = _stopMessage(stop!);
      }
    });
  }

  static String _livenessMessage(LivenessResult result, LivenessPose pose) {
    final photo = pose == LivenessPose.straight ? 'photo 1' : 'photo 2';
    return switch (result) {
      LivenessResult.noFace =>
        'No face was found in $photo. Hold the phone at eye level in good light and try again.',
      LivenessResult.multipleFaces =>
        'More than one face is in $photo. Make sure only you are in the frame.',
      LivenessResult.eyesClosed =>
        'Your eyes look closed in photo 1. Keep both eyes open and look at the camera.',
      LivenessResult.notStraight =>
        'In photo 1, look straight at the camera, not to the side.',
      LivenessResult.notTurned =>
        'Your head is not turned enough in photo 2. Turn it further to the left or right.',
      LivenessResult.failed || LivenessResult.passed =>
        'The photo could not be checked. Try again in better light.',
    };
  }

  static String _refusalMessage(FaceCheckRefusal refusal) => switch (refusal) {
    FaceCheckRefusal.noFace =>
      'No face was found in the photo. Use good light and keep your whole face in the frame.',
    FaceCheckRefusal.multipleFaces =>
      'The photo shows more than one face. Make sure only you are in the photo.',
    FaceCheckRefusal.notMatched =>
      'The photo did not match your reference photo. Face the light, remove sunglasses or a mask, and try again.',
    FaceCheckRefusal.invalidPhoto =>
      'The photo was not accepted. Use a JPEG or PNG photo smaller than 10 MiB.',
  };

  static String _stopMessage(FaceCheckStop stop) => switch (stop) {
    FaceCheckStop.tooManyAttempts =>
      'Too many face check attempts. No money was sent. Wait a few minutes, then start a new review.',
    FaceCheckStop.signIn =>
      'This face check is not allowed for the current sign-in. No money was sent. Sign out, sign in again and start a new review.',
    FaceCheckStop.notAvailable =>
      'A face check is not possible for this review, for example because your reference photo is no longer accepted. No money was sent. Check Identity reference in My profile, then start a new review.',
  };

  @override
  Widget build(BuildContext context) {
    final working = _working;
    final ready = widget.enabled && working == null;
    final photoOneDone =
        _phase == _FacePhase.turned ||
        (_device && _phase == _FacePhase.sending);
    final (String, VoidCallback)? action = switch (_phase) {
      _FacePhase.straight => (
        _device ? 'Take photo 1' : 'Take or choose a photo',
        _take,
      ),
      _FacePhase.turned => ('Take photo 2', _take),
      _FacePhase.retry => ('Try the face check again', _take),
      _FacePhase.resend => ('Send the same photo again', _resend),
      _FacePhase.sending || _FacePhase.stopped => null,
    };
    return _Panel(
      children: [
        const Center(
          child: _IconBadge(
            Icons.face_outlined,
            tone: _Tone.info,
            size: 56,
            circle: true,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Face check required',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          _device
              ? 'This transfer is over 10,000,000 VND, or takes today\'s transfers over 20,000,000 VND. Take two selfies with the front camera. Only photo 1 is sent: Nene compares it with your accepted reference photo on its server, then discards it.'
              : 'This transfer is over 10,000,000 VND, or takes today\'s transfers over 20,000,000 VND. Take or choose one clear, recent photo of your face. Nene compares it with your accepted reference photo on its server, then discards it. Head-movement checks run only in the Android app.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: NeneColors.muted, fontSize: 13.5),
        ),
        if (_device) ...[
          const SizedBox(height: 16),
          _FaceStepRow(
            number: 1,
            text: 'Look straight at the camera with both eyes open',
            done: photoOneDone,
          ),
          const SizedBox(height: 10),
          _FaceStepRow(
            number: 2,
            text: 'Turn your head to the left or right',
            done: _device && _phase == _FacePhase.sending,
          ),
        ],
        if (working != null) ...[
          const SizedBox(height: 18),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(semanticsLabel: working),
          ),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              working,
              textAlign: TextAlign.center,
              style: const TextStyle(color: NeneColors.muted, fontSize: 13),
            ),
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 16),
          _Alert(
            _message!,
            tone: _phase == _FacePhase.stopped ? _Tone.error : _Tone.warning,
          ),
        ],
        if (_failures > 0 && _phase != _FacePhase.stopped) ...[
          const SizedBox(height: 8),
          Text(
            'Attempts left for this review: ${maximumFaceCheckFailures - _failures}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: NeneColors.muted, fontSize: 13),
          ),
        ],
        if (action != null) ...[
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: ready ? action.$2 : null,
            icon: Icon(
              _phase == _FacePhase.resend
                  ? Icons.refresh_rounded
                  : Icons.photo_camera_front_outlined,
              size: 20,
            ),
            label: Text(action.$1),
          ),
        ],
        if (_phase == _FacePhase.resend) ...[
          const SizedBox(height: 4),
          TextButton(
            onPressed: ready ? _take : null,
            child: const Text('Take new photos'),
          ),
        ],
      ],
    );
  }
}

class _FaceStepRow extends StatelessWidget {
  const _FaceStepRow({
    required this.number,
    required this.text,
    required this.done,
  });
  final int number;
  final String text;
  final bool done;

  @override
  Widget build(BuildContext context) {
    // The circle grows with the text size so the number stays inside it.
    final side = MediaQuery.textScalerOf(context).scale(14) + 14;
    return Row(
      children: [
        Container(
          width: side,
          height: side,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done ? _Tone.success.background : _Tone.info.background,
            shape: BoxShape.circle,
          ),
          child: done
              ? Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: _Tone.success.foreground,
                  semanticLabel: 'Done',
                )
              : Text(
                  '$number',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _Tone.info.foreground,
                  ),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 14, color: NeneColors.ink),
          ),
        ),
      ],
    );
  }
}

/// Tinted color pairs for icons, pills and callouts on this flow.
enum _Tone {
  info(NeneColors.pale, NeneColors.action),
  success(Color(0xFFE3F3EA), NeneColors.positive),
  warning(NeneColors.apricotSoft, NeneColors.deep),
  error(Color(0xFFFBEAEA), Color(0xFF9B3434)),
  neutral(NeneColors.line, NeneColors.muted);

  const _Tone(this.background, this.foreground);
  final Color background, foreground;
}

class _IconBadge extends StatelessWidget {
  const _IconBadge(
    this.icon, {
    required this.tone,
    this.size = 44,
    this.circle = false,
  });
  final IconData icon;
  final _Tone tone;
  final double size;
  final bool circle;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: tone.background,
      shape: circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: circle ? null : BorderRadius.circular(size * .32),
    ),
    child: Icon(icon, color: tone.foreground, size: size * .5),
  );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: _Tone.warning.background,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: _Tone.warning.foreground,
      ),
    ),
  );
}

/// White bordered surface matching the workspace cards.
class _Panel extends StatelessWidget {
  const _Panel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: NeneColors.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: NeneColors.pale,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: NeneColors.action),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              color: NeneColors.muted,
              fontFeatures: neneTabularFigures,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Alert extends StatelessWidget {
  const _Alert(this.text, {required this.tone});
  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            tone == _Tone.error
                ? Icons.error_outline_rounded
                : Icons.warning_amber_rounded,
            size: 20,
            color: tone.foreground,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13.5, color: NeneColors.ink),
            ),
          ),
        ],
      ),
    ),
  );
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.label, required this.account});
  final String label;
  final BankAccount account;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: NeneColors.line),
    ),
    child: Row(
      children: [
        _IconBadge(
          account.type == 'saving'
              ? Icons.savings_outlined
              : Icons.account_balance_wallet_outlined,
          tone: _Tone.info,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(color: NeneColors.muted, fontSize: 13),
              ),
              const SizedBox(height: 2),
              Text(
                account.typeLabel,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                account.accountNumber,
                style: const TextStyle(
                  color: NeneColors.muted,
                  fontSize: 13.5,
                  letterSpacing: .8,
                  fontFeatures: neneTabularFigures,
                ),
              ),
            ],
          ),
        ),
        if (account.isDemo) const _Pill('Demo'),
      ],
    ),
  );
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({
    required this.icon,
    required this.tone,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final _Tone tone;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Center(child: _IconBadge(icon, tone: tone, size: 64, circle: true)),
      const SizedBox(height: 14),
      Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 20),
      ),
      const SizedBox(height: 6),
      Semantics(
        liveRegion: true,
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: NeneColors.muted, fontSize: 14),
        ),
      ),
    ],
  );
}

/// Review summary or receipt: optional outcome header, emphasized amount and
/// label/value detail rows.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    this.header,
    required this.badge,
    required this.caption,
    this.amount,
    this.note,
    required this.rows,
  });
  final Widget? header;
  final String badge;
  final String caption;
  final String? amount;
  final String? note;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final receipt = header != null;
    final align = receipt ? TextAlign.center : TextAlign.start;
    const muted = TextStyle(color: NeneColors.muted, fontSize: 13);
    return _Panel(
      children: [
        if (receipt) ...[header!, const SizedBox(height: 20)],
        if (!receipt)
          // Wraps the label under the caption at narrow widths or large text.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Text(caption, style: muted),
              _Pill(badge),
            ],
          )
        else if (amount != null)
          Text(caption, textAlign: align, style: muted),
        if (amount != null) ...[
          const SizedBox(height: 4),
          Text(
            amount!,
            textAlign: align,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
              color: NeneColors.ink,
              fontFeatures: neneTabularFigures,
            ),
          ),
        ],
        if (note != null) ...[
          const SizedBox(height: 2),
          Text(note!, textAlign: align, style: muted),
        ],
        if (receipt) ...[
          const SizedBox(height: 12),
          Center(child: _Pill(badge)),
        ],
        if (rows.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Divider(),
          ),
          for (final (label, value) in rows) _DetailRow(label, value),
        ],
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 130),
          child: Text(label, style: const TextStyle(color: NeneColors.muted)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontFeatures: neneTabularFigures,
            ),
          ),
        ),
      ],
    ),
  );
}
