import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/identity_repository.dart';
import '../data/reference_photo_source.dart';
import '../identity_controller.dart';
import '../session_controller.dart';
import 'nene_brand.dart';

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
                  const SizedBox(height: 10),
                  const Text(
                    'A private photo for officer-assisted enrollment. Reference acceptance is separate from later identity checks.',
                  ),
                  const SizedBox(height: 20),
                  if (value != null) ...[
                    Text(
                      value.customerName,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    _Notice(
                      _flow.mustCheckStatus
                          ? 'Status not confirmed'
                          : value.label,
                      key: const ValueKey('reference-status'),
                    ),
                    if (value.correctionReason != null) ...[
                      const SizedBox(height: 12),
                      Text('Correction: ${value.correctionReason}'),
                    ],
                    if (value.expiresAt != null && !value.expired) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Photo access expires ${_date(value.expiresAt!)}.',
                        style: const TextStyle(color: NeneColors.muted),
                      ),
                    ],
                  ],
                  if (_flow.busy || _flow.capturing) ...[
                    const SizedBox(height: 18),
                    const LinearProgressIndicator(
                      semanticsLabel: 'Working on identity reference',
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _flow.capturing
                          ? 'Complete or cancel the device photo picker.'
                          : 'Please wait…',
                    ),
                  ],
                  if (_flow.message != null) ...[
                    const SizedBox(height: 16),
                    _Notice(_flow.message!),
                  ],
                  if (_flow.error != null) ...[
                    const SizedBox(height: 16),
                    _Notice(_flow.error!, error: true),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _flow.busy || _flow.capturing
                        ? null
                        : _flow.load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check status'),
                  ),
                  if (_flow.canRetry) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'The last action is not confirmed. Retry sends the same request safely.',
                    ),
                    FilledButton(
                      onPressed: _flow.retry,
                      child: const Text('Retry last action'),
                    ),
                  ],
                  if (canStart && value != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Before you begin',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(value.noticeText),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _acknowledged,
                      onChanged: blocked
                          ? null
                          : (v) => setState(() => _acknowledged = v ?? false),
                      title: Text(
                        _flow.officer
                            ? 'The customer requested assistance and acknowledged this notice.'
                            : 'I understand this notice and agree to submit an agreed test image.',
                      ),
                    ),
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
                  if (photo != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      _flow.captured != null
                          ? 'Photo preview · not uploaded'
                          : 'Private reference photo',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    _PrivatePhoto(bytes: photo),
                  ],
                  if (canCapture) ...[
                    const SizedBox(height: 20),
                    const Text(
                      'Use one clear JPEG or PNG photo. Maximum 10 MiB and 4096 × 4096 pixels.',
                    ),
                    if (kIsWeb) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Browser preview uses a photo picker. Your browser may offer a camera; selecting a file does not prove live capture.',
                        style: TextStyle(color: NeneColors.muted),
                      ),
                    ],
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: blocked ? null : _flow.capture,
                      icon: Icon(
                        kIsWeb
                            ? Icons.add_photo_alternate_outlined
                            : Icons.camera_alt_outlined,
                      ),
                      label: Text(
                        kIsWeb
                            ? 'Choose photo'
                            : photo == null
                            ? 'Take photo'
                            : 'Retake photo',
                      ),
                    ),
                    if (_flow.captured != null) ...[
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: blocked ? null : _flow.upload,
                        child: const Text('Save photo privately'),
                      ),
                    ],
                    if (_flow.captured == null &&
                        (value?.allowedActions.contains('submit') ??
                            false)) ...[
                      const SizedBox(height: 10),
                      const Text(
                        'Check the customer name and photo before submitting. Name corrections require officer assistance.',
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: blocked || _flow.evidence == null
                            ? null
                            : _flow.submit,
                        child: const Text('Submit reference'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      _flow.officer
                          ? 'If capture is unavailable, ask the customer to submit from their device and return here to review.'
                          : 'Camera unavailable or name incorrect? Ask your bank officer to assist with this reference.',
                      style: const TextStyle(color: NeneColors.muted),
                    ),
                  ],
                  if (value?.status == 'submitted' && !_flow.officer) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'Your officer will review the reference and confirm that it belongs to you. Check status here for a correction or acceptance.',
                    ),
                  ],
                  if (canReview) ...[
                    const SizedBox(height: 24),
                    Text(
                      'Officer review',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Compare this photo with the customer you are assisting. A name and uploaded photo alone are not sufficient to confirm the association.',
                    ),
                    if (_confirmingReview != null) ...[
                      const SizedBox(height: 14),
                      _Notice(
                        '${_confirmingReview! ? 'Accept reference' : 'Request correction'} for ${value!.customerName}, revision ${value.revision}?\n\n${_confirmingReview! ? 'Acceptance records your confirmation of the customer/photo association. It does not complete eKYC.' : _reason.text.trim()}',
                      ),
                      const SizedBox(height: 12),
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
                      TextButton(
                        onPressed: blocked
                            ? null
                            : () => setState(() => _confirmingReview = null),
                        child: const Text('Back to review'),
                      ),
                    ] else ...[
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _association,
                        onChanged: blocked || _flow.evidence == null
                            ? null
                            : (v) => setState(() => _association = v ?? false),
                        title: const Text(
                          'I confirm this reference belongs to the selected customer I assisted.',
                        ),
                      ),
                      FilledButton(
                        onPressed:
                            blocked || !_association || _flow.evidence == null
                            ? null
                            : () => _confirmReview(true),
                        child: const Text('Accept reference'),
                      ),
                      const SizedBox(height: 24),
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
                      OutlinedButton(
                        onPressed: blocked || _reason.text.trim().length < 5
                            ? null
                            : () => _confirmReview(false),
                        child: const Text('Request correction'),
                      ),
                    ],
                  ],
                  if (value?.status == 'reference_accepted' &&
                      !_flow.mustCheckStatus) ...[
                    const SizedBox(height: 20),
                    const _Notice(
                      'Reference accepted for later identity checks. This does not complete eKYC, prove live presence or authorize a transaction.',
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
}

String _date(DateTime date) {
  final local = date.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

class _Notice extends StatelessWidget {
  const _Notice(this.text, {super.key, this.error = false});
  final String text;
  final bool error;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(16),
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
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
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
      errorBuilder: (_, _, _) => const Text(
        'Photo preview unavailable. Check status before reviewing.',
      ),
    ),
  );
}
