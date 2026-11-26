import 'package:flutter/material.dart';

import '../data/security_api.dart';
import 'nene_brand.dart';

/// Offers Nene Smart OTP when this phone holds a key for the signed-in person.
/// After the fingerprint / screen-lock prompt it hands a fresh 6-digit code to
/// [onCode]; the server checks it like any authenticator code.
class SmartOtpButton extends StatefulWidget {
  const SmartOtpButton({
    super.key,
    required this.api,
    required this.onCode,
    this.enabled = true,
    this.label = 'Confirm with Smart OTP',
  });
  final SecurityApi api;
  final ValueChanged<String> onCode;
  final bool enabled;
  final String label;

  @override
  State<SmartOtpButton> createState() => _SmartOtpButtonState();
}

class _SmartOtpButtonState extends State<SmartOtpButton> {
  bool _ready = false, _busy = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final userId = widget.api.userId;
    if (userId == null) return;
    final ready = await widget.api.smartOtp.enabled(userId);
    if (mounted) setState(() => _ready = ready);
  }

  Future<void> _use() async {
    final userId = widget.api.userId;
    if (userId == null || _busy) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    final code = await widget.api.smartOtp.code(userId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = code == null
          ? 'Smart OTP was cancelled. Try again, or type a code from an authenticator app.'
          : null;
    });
    if (code != null) widget.onCode(code);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            onPressed: widget.enabled && !_busy ? _use : null,
            icon: const Icon(Icons.fingerprint_rounded),
            label: Text(_busy ? 'Getting a fresh code…' : widget.label),
          ),
          if (_busy) ...[
            const SizedBox(height: 6),
            const Text(
              'A new code can take up to 30 seconds after the previous one.',
              textAlign: TextAlign.center,
              style: TextStyle(color: NeneColors.muted, fontSize: 12.5),
            ),
          ],
          if (_note != null) ...[
            const SizedBox(height: 6),
            Text(
              _note!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: NeneColors.muted, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }
}
