import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/identity_repository.dart';
import '../data/reference_photo_source.dart';
import '../identity_controller.dart';
import '../session_controller.dart';
import 'nene_brand.dart';
import 'nene_components.dart';

const _errorTint = Color(0xFFFBECEC);
const _positiveTint = Color(0xFFE3F3EA);

/// This screen stays inside the authenticated workspace; it never pushes a
/// route above the sign-in boundary or retains images between visits.
class IdentityReferenceScreen extends StatefulWidget {
  const IdentityReferenceScreen({
    super.key,
    required this.session,
    required this.repository,
    required this.photos,
    this.customerId,
  });
  final SessionController session;
  final IdentityRepository repository;
  final ReferencePhotoSource photos;
  final String? customerId;

  @override
  State<IdentityReferenceScreen> createState() =>
      _IdentityReferenceScreenState();
}

class _IdentityReferenceScreenState extends State<IdentityReferenceScreen> {
  late final IdentityController _flow;
  final _reason = TextEditingController();
  bool _acknowledged = false;
  bool _association = false;
  bool? _confirmingReview;
  int? _reviewVersion;

  @override
  void initState() {
    super.initState();
    _flow = IdentityController(
      session: widget.session,
      repository: widget.repository,
      photos: widget.photos,
      customerId: widget.customerId,
    );
    _flow.addListener(_changed);
    unawaited(_flow.load());
  }

  void _changed() {
    if (_reviewVersion != _flow.summary?.version) {
      _reviewVersion = _flow.summary?.version;
      _association = false;
      _confirmingReview = null;
      _reason.clear();
    }
  }

  @override
  void dispose() {
    _flow.removeListener(_changed);
    _flow.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _confirmReview(bool accept) {
    final reason = _reason.text.trim();
    if (!accept && (reason.length < 5 || reason.length > 500)) return;
    FocusScope.of(context).unfocus();
    setState(() => _confirmingReview = accept);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _flow,
    builder: (context, _) {
      final value = _flow.summary;
      final photo = _flow.captured?.bytes ?? _flow.evidence;
      final blocked = _flow.blocked;
      final canStart = value?.allowedActions.contains('start') ?? false;
      final canCapture = value?.allowedActions.contains('capture') ?? false;
      final canReview =
          _flow.officer &&
          (value?.allowedActions.contains('accept_reference') ?? false);
      return SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Identity reference',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'A private photo for officer-assisted enrollment. Reference acceptance is separate from later identity checks.',
                    style: TextStyle(color: NeneColors.muted),
                  ),
                  const SizedBox(height: 20),
                  _statusCard(value),
                  if (_flow.busy || _flow.capturing) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(
                      semanticsLabel: 'Working on identity reference',
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _flow.capturing
                          ? 'Complete or cancel the device photo picker.'
                          : 'Please wait…',
                      style: const TextStyle(color: NeneColors.muted),
                    ),
                  ],
                  if (_flow.message != null) ...[
                    const SizedBox(height: 16),
                    _Notice(_flow.message!, icon: Icons.info_outline_rounded),
                  ],
                  if (_flow.error != null) ...[
                    const SizedBox(height: 16),
                    _Notice(
                      _flow.error!,
                      icon: Icons.error_outline_rounded,
                      error: true,
                    ),
                  ],
                  if (_flow.canRetry) ...[
                    const SizedBox(height: 16),
                    _Panel(
                      color: NeneColors.apricotSoft,
                      children: [
                        const _IconText(
                          Icons.sync_problem_rounded,
                          'The last action is not confirmed. Retry sends the same request safely.',
                        ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: _flow.retry,
                          child: const Text('Retry last action'),
                        ),
                      ],
                    ),
                  ],
                  if (canStart && value != null) ...[
                    const SizedBox(height: 24),
                    const SectionTitle('Before you begin'),
                    _Panel(
                      children: [
                        const _IconText(
                          Icons.privacy_tip_outlined,
                          'Privacy notice',
                          strong: true,
                        ),
                        const SizedBox(height: 10),
                        Text(value.noticeText),
                        const Divider(height: 28),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _acknowledged,
                          onChanged: blocked
                              ? null
                              : (v) =>
                                    setState(() => _acknowledged = v ?? false),
                          title: Text(
                            _flow.officer
                                ? 'The customer requested assistance and acknowledged this notice.'
                                : 'I understand this notice and agree to submit an agreed test image.',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: blocked || !_acknowledged
                          ? null
                          : () => _flow.start(acknowledged: _acknowledged),
                      child: Text(
                        value.status == 'not_started'
                            ? 'Start reference'
                            : 'Continue with a new reference',
                      ),
                    ),
                  ],
                  if (photo != null || canCapture) ...[
                    const SizedBox(height: 24),
                    SectionTitle(
                      photo == null
                          ? 'Reference photo'
                          : _flow.captured != null
                          ? 'Photo preview · not uploaded'
                          : 'Private reference photo',
                    ),
                    _Panel(
                      children: [
                        photo == null
                            ? const _EmptyFrame()
                            : _PrivatePhoto(bytes: photo),
                        if (canCapture) ...[
                          const SizedBox(height: 14),
                          const _IconText(
                            Icons.photo_size_select_large_rounded,
                            'Use one clear JPEG or PNG photo. Maximum 10 MiB and 4096 × 4096 pixels.',
                            muted: true,
                          ),
                          if (kIsWeb) ...[
                            const SizedBox(height: 8),
                            const _IconText(
                              Icons.web_rounded,
                              'Browser preview uses a photo picker. Your browser may offer a camera; selecting a file does not prove live capture.',
                              muted: true,
                            ),
                          ],
                        ],
                      ],
                    ),
                  ],
                  if (canCapture) ..._captureActions(value!, photo, blocked),
                  if (value?.status == 'submitted' && !_flow.officer) ...[
                    const SizedBox(height: 16),
                    const _Panel(
                      color: NeneColors.pale,
                      children: [
                        _IconText(
                          Icons.hourglass_top_rounded,
                          'Your officer will review the reference and confirm that it belongs to you. Check status here for a correction or acceptance.',
                        ),
                      ],
                    ),
                  ],
                  if (canReview) ..._officerReview(value!, blocked),
                  if (value?.status == 'reference_accepted' &&
                      !_flow.mustCheckStatus) ...[
                    const SizedBox(height: 16),
                    const _Panel(
                      color: _positiveTint,
                      children: [
                        _IconText(
                          Icons.info_outline_rounded,
                          'Reference accepted for later identity checks. This does not complete eKYC, prove live presence or authorize a transaction.',
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  /// Current state at a glance, with the status refresh beside it.
  Widget _statusCard(IdentitySummary? value) {
    final label = value == null
        ? (_flow.busy ? 'Checking status' : 'Status not confirmed')
        : _flow.mustCheckStatus
        ? 'Status not confirmed'
        : value.label;
    final (
      icon,
      background,
      foreground,
    ) = value == null || _flow.mustCheckStatus
        ? (Icons.sync_problem_rounded, NeneColors.apricotSoft, NeneColors.deep)
        : switch (value.status) {
            'draft' => (
              Icons.photo_camera_outlined,
              NeneColors.pale,
              NeneColors.action,
            ),
            'submitted' => (
              Icons.hourglass_top_rounded,
              NeneColors.apricotSoft,
              NeneColors.deep,
            ),
            'needs_changes' when value.expired => (
              Icons.timer_off_outlined,
              NeneColors.line,
              NeneColors.muted,
            ),
            'needs_changes' => (
              Icons.edit_note_rounded,
              _errorTint,
              Theme.of(context).colorScheme.error,
            ),
            'reference_accepted' => (
              Icons.check_circle_outline_rounded,
              _positiveTint,
              NeneColors.positive,
            ),
            _ => (Icons.portrait_outlined, NeneColors.line, NeneColors.muted),
          };
    return _Panel(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
      children: [
        Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: foreground, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (value != null)
                    Text(
                      value.customerName,
                      style: const TextStyle(
                        color: NeneColors.muted,
                        fontSize: 13.5,
                      ),
                    ),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      label,
                      key: const ValueKey('reference-status'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (value?.correctionReason != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: value!.expired ? NeneColors.ivory : _errorTint,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Correction reason',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: NeneColors.muted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(value.correctionReason!),
              ],
            ),
          ),
        ],
        if (value?.expiresAt != null && !value!.expired) ...[
          const SizedBox(height: 12),
          _IconText(
            Icons.schedule_rounded,
            'Photo access expires ${_date(value.expiresAt!)}.',
            muted: true,
          ),
        ],
        const Divider(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _flow.busy || _flow.capturing ? null : _flow.load,
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text('Check status'),
          ),
        ),
      ],
    );
  }

  List<Widget> _captureActions(
    IdentitySummary value,
    Uint8List? photo,
    bool blocked,
  ) {
    final captureLabel = kIsWeb
        ? 'Choose photo'
        : photo == null
        ? 'Take photo'
        : 'Retake photo';
    final captureIcon = Icon(
      kIsWeb ? Icons.add_photo_alternate_outlined : Icons.camera_alt_outlined,
    );
    final submit =
        _flow.captured == null && value.allowedActions.contains('submit');
    // With nothing to save or submit, taking the photo is the next step.
    final captureIsPrimary = _flow.captured == null && !submit;
    return [
      const SizedBox(height: 16),
      if (submit) ...[
        const Text(
          'Check the customer name and photo before submitting. Name corrections require officer assistance.',
          style: TextStyle(color: NeneColors.muted),
        ),
        const SizedBox(height: 12),
      ],
      captureIsPrimary
          ? FilledButton.icon(
              onPressed: blocked ? null : _flow.capture,
              icon: captureIcon,
              label: Text(captureLabel),
            )
          : OutlinedButton.icon(
              onPressed: blocked ? null : _flow.capture,
              icon: captureIcon,
              label: Text(captureLabel),
            ),
      if (_flow.captured != null) ...[
        const SizedBox(height: 10),
        FilledButton(
          onPressed: blocked ? null : _flow.upload,
          child: const Text('Save photo privately'),
        ),
      ],
      if (submit) ...[
        const SizedBox(height: 10),
        FilledButton(
          onPressed: blocked || _flow.evidence == null ? null : _flow.submit,
          child: const Text('Submit reference'),
        ),
      ],
      const SizedBox(height: 14),
      _IconText(
        Icons.support_agent_rounded,
        _flow.officer
            ? 'If capture is unavailable, ask the customer to submit from their device and return here to review.'
            : 'Camera unavailable or name incorrect? Ask your bank officer to assist with this reference.',
        muted: true,
      ),
    ];
  }

  List<Widget> _officerReview(IdentitySummary value, bool blocked) => [
    const SizedBox(height: 28),
    const SectionTitle('Officer review', trailing: _OfficerPill()),
    _Panel(
      children: [
        const _IconText(
          Icons.compare_outlined,
          'Compare this photo with the customer you are assisting. A name and uploaded photo alone are not sufficient to confirm the association.',
        ),
        const SizedBox(height: 16),
        if (_confirmingReview != null) ...[
          _Notice(
            '${_confirmingReview! ? 'Accept reference' : 'Request correction'} for ${value.customerName}, revision ${value.revision}?\n\n${_confirmingReview! ? 'Acceptance records your confirmation of the customer/photo association. It does not complete eKYC.' : _reason.text.trim()}',
            icon: _confirmingReview!
                ? Icons.how_to_reg_outlined
                : Icons.edit_note_rounded,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: blocked
                ? null
                : () => _flow.review(
                    accept: _confirmingReview!,
                    associationConfirmed: _association,
                    reason: _reason.text.trim(),
                  ),
            child: const Text('Confirm review decision'),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: blocked
                ? null
                : () => setState(() => _confirmingReview = null),
            child: const Text('Back to review'),
          ),
        ] else ...[
          Material(
            color: NeneColors.pale,
            borderRadius: BorderRadius.circular(14),
            child: CheckboxListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              controlAffinity: ListTileControlAffinity.leading,
              value: _association,
              onChanged: blocked || _flow.evidence == null
                  ? null
                  : (v) => setState(() => _association = v ?? false),
              title: const Text(
                'I confirm this reference belongs to the selected customer I assisted.',
              ),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: blocked || !_association || _flow.evidence == null
                ? null
                : () => _confirmReview(true),
            child: const Text('Accept reference'),
          ),
          const SizedBox(height: 24),
          const Row(
            children: [
              Expanded(child: Divider()),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'or',
                  style: TextStyle(color: NeneColors.muted, fontSize: 13),
                ),
              ),
              Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _reason,
            enabled: !blocked,
            minLines: 2,
            maxLines: 5,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Correction reason',
              helperText: 'Give a useful reason, 5–500 characters.',
              helperMaxLines: 4,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: blocked || _reason.text.trim().length < 5
                ? null
                : () => _confirmReview(false),
            icon: const Icon(Icons.edit_note_rounded),
            label: const Text('Request correction'),
          ),
        ],
      ],
    ),
  ];
}

String _date(DateTime date) {
  final local = date.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// White rounded card (or a tinted panel) holding one section.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.children,
    this.color = Colors.white,
    this.padding = const EdgeInsets.all(18),
  });
  final List<Widget> children;
  final Color color;
  final EdgeInsets padding;

  // A Material (not a decorated box) so checkbox tiles keep their ink.
  @override
  Widget build(BuildContext context) => Material(
    color: color,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: color == Colors.white
          ? const BorderSide(color: NeneColors.line)
          : BorderSide.none,
    ),
    child: Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

class _IconText extends StatelessWidget {
  const _IconText(
    this.icon,
    this.text, {
    this.muted = false,
    this.strong = false,
  });
  final IconData icon;
  final String text;
  final bool muted;
  final bool strong;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        icon,
        size: muted ? 18 : 20,
        color: muted ? NeneColors.muted : NeneColors.action,
      ),
      SizedBox(width: muted ? 10 : 12),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            color: muted ? NeneColors.muted : NeneColors.ink,
            fontSize: muted ? 13 : null,
            fontWeight: strong ? FontWeight.w700 : null,
          ),
        ),
      ),
    ],
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text, {required this.icon, this.error = false});
  final String text;
  final IconData icon;
  final bool error;
  @override
  Widget build(BuildContext context) {
    final color = error ? Theme.of(context).colorScheme.error : NeneColors.deep;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: error ? _errorTint : NeneColors.pale,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: error ? color : NeneColors.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OfficerPill extends StatelessWidget {
  const _OfficerPill();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: NeneColors.apricotSoft,
      borderRadius: BorderRadius.circular(99),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.badge_outlined, size: 14, color: NeneColors.deep),
        SizedBox(width: 5),
        Text(
          'Officer only',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: NeneColors.deep,
          ),
        ),
      ],
    ),
  );
}

/// Placeholder frame shown before a photo exists.
class _EmptyFrame extends StatelessWidget {
  const _EmptyFrame();

  @override
  Widget build(BuildContext context) => Container(
    height: 180,
    decoration: BoxDecoration(
      color: NeneColors.ivory,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: NeneColors.line),
    ),
    child: const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.add_a_photo_outlined, size: 36, color: NeneColors.brand),
        SizedBox(height: 10),
        Text('No photo yet', style: TextStyle(color: NeneColors.muted)),
      ],
    ),
  );
}

class _PrivatePhoto extends StatefulWidget {
  const _PrivatePhoto({required this.bytes});
  final Uint8List bytes;
  @override
  State<_PrivatePhoto> createState() => _PrivatePhotoState();
}

class _PrivatePhotoState extends State<_PrivatePhoto> {
  late MemoryImage _provider = MemoryImage(widget.bytes);
  @override
  void didUpdateWidget(_PrivatePhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      unawaited(_provider.evict());
      _provider = MemoryImage(widget.bytes);
    }
  }

  @override
  void dispose() {
    unawaited(_provider.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: NeneColors.ivory,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: NeneColors.line),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image(
        image: _provider,
        height: 240,
        fit: BoxFit.contain,
        semanticLabel: 'Private reference photo for the selected customer',
        frameBuilder: (_, child, frame, wasSynchronouslyLoaded) =>
            frame != null || wasSynchronouslyLoaded
            ? child
            : const SizedBox(
                height: 240,
                child: Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: 'Loading private photo',
                  ),
                ),
              ),
        errorBuilder: (_, _, _) => const SizedBox(
          height: 120,
          child: Center(
            child: Text(
              'Photo preview unavailable. Check status before reviewing.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ),
  );
}
