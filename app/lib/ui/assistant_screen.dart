import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../assistant_controller.dart';
import '../data/assistant_api.dart';
import 'nene_brand.dart';
import 'nene_components.dart';

/// Example questions the rule-based assistant understands. Tapping one sends
/// its text through the ordinary send path.
const _suggestions = [
  (Icons.history_rounded, 'Transactions this month'),
  (Icons.send_rounded, 'Transfer money'),
  (Icons.receipt_long_outlined, 'Pay my electricity bill'),
  (Icons.phone_iphone_rounded, 'Top up my phone'),
];

const _errorTint = Color(0xFFFBECEC);

IconData _activityIcon(AssistantActivity activity) => switch (activity) {
  AssistantActivity.history => Icons.history_rounded,
  AssistantActivity.transfer => Icons.send_rounded,
  AssistantActivity.interbankTransfer => Icons.account_balance_outlined,
  AssistantActivity.deposit => Icons.add_card_outlined,
  AssistantActivity.withdrawal => Icons.payments_outlined,
  AssistantActivity.bills => Icons.receipt_long_outlined,
  AssistantActivity.phone => Icons.phone_iphone_rounded,
  AssistantActivity.movieTickets => Icons.local_movies_outlined,
};

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({
    super.key,
    required this.controller,
    required this.onAction,
  });
  final AssistantController controller;
  final ValueChanged<AssistantAction> onAction;
  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send([String? suggestion]) {
    final text = suggestion ?? _text.text;
    if (widget.controller.busy ||
        text.trim().isEmpty ||
        text.trim().length > 500) {
      return;
    }
    _text.clear();
    FocusScope.of(context).unfocus();
    widget.controller.send(text);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final chat = widget.controller;
      final empty = chat.messages.isEmpty && !chat.busy && chat.error == null;
      return SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                _header(chat, canClear: !empty),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Leave room for the avatar column beside replies.
                      final bubble = math.min(
                        (constraints.maxWidth - 32 - 40) * .9,
                        520.0,
                      );
                      return ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                        children: empty
                            ? [_welcome(chat)]
                            : [
                                const _SessionNote(),
                                for (final message in chat.messages)
                                  message.isCustomer
                                      ? _CustomerBubble(
                                          message.text,
                                          maxWidth: bubble,
                                        )
                                      : _AssistantBubble(
                                          message,
                                          maxWidth: bubble,
                                          busy: chat.busy,
                                          onAction: widget.onAction,
                                        ),
                                if (chat.busy) const _TypingBubble(),
                                if (chat.error != null)
                                  _ErrorCard(
                                    chat.error!,
                                    onRetry: chat.busy ? null : chat.retry,
                                  ),
                              ],
                      );
                    },
                  ),
                ),
                if (!empty) _quickReplies(chat),
                _composer(chat),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _header(AssistantController chat, {required bool canClear}) =>
      Container(
        padding: const EdgeInsets.fromLTRB(20, 8, 8, 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: NeneColors.line)),
        ),
        child: Row(
          children: [
            const _NeneMark(size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Nene assistant',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Text(
                    'Finds the right screen · replies in English',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: NeneColors.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Clear conversation',
              onPressed: canClear ? chat.clear : null,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      );

  Widget _welcome(AssistantController chat) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: _NeneMark(size: 56)),
        const SizedBox(height: 14),
        Text(
          'How can I help?',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        const Text(
          'Ask about an activity in English or Vietnamese. This assistant '
          'understands a limited set of requests, replies in English and '
          'opens the right screen. You review and confirm any transaction in '
          'its usual flow.',
          textAlign: TextAlign.center,
          style: TextStyle(color: NeneColors.muted, fontSize: 13.5),
        ),
        const SizedBox(height: 20),
        const SectionTitle('Try asking'),
        // Two equal-height cards per row, even when large text wraps labels.
        for (var row = 0; row < _suggestions.length; row += 2) ...[
          if (row > 0) const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = row; i < row + 2; i++) ...[
                  if (i > row) const SizedBox(width: 10),
                  Expanded(
                    child: _SuggestionCard(
                      icon: _suggestions[i].$1,
                      label: _suggestions[i].$2,
                      onTap: chat.busy ? null : () => _send(_suggestions[i].$2),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: NeneColors.apricotSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline_rounded, color: NeneColors.deep),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Keep passwords, codes and personal details out of chat. '
                  'This conversation is kept only for your current session.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _quickReplies(AssistantController chat) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
    child: Row(
      children: [
        for (final (i, (icon, label)) in _suggestions.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          _SuggestionChip(
            icon: icon,
            label: label,
            onTap: chat.busy ? null : () => _send(label),
          ),
        ],
      ],
    ),
  );

  Widget _composer(AssistantController chat) {
    const radius = BorderRadius.all(Radius.circular(24));
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: NeneColors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _text,
              enabled: !chat.busy,
              maxLength: 500,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              // The limit stays enforced; the counter appears near it.
              buildCounter:
                  (
                    _, {
                    required currentLength,
                    required isFocused,
                    required maxLength,
                  }) => currentLength < 400
                  ? null
                  : Text(
                      '$currentLength/$maxLength',
                      style: const TextStyle(
                        fontSize: 12,
                        color: NeneColors.muted,
                        fontFeatures: neneTabularFigures,
                      ),
                    ),
              decoration: const InputDecoration(
                hintText: 'Ask Nene',
                hintMaxLines: 1,
                hintStyle: TextStyle(color: NeneColors.muted),
                fillColor: NeneColors.ivory,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 13,
                ),
                border: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide(color: NeneColors.line),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide(color: NeneColors.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: radius,
                  borderSide: BorderSide(color: NeneColors.action, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Send message',
            onPressed: chat.busy ? null : () => _send(),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(48),
              backgroundColor: NeneColors.action,
              foregroundColor: Colors.white,
              disabledBackgroundColor: NeneColors.line,
              disabledForegroundColor: NeneColors.muted,
            ),
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
        ],
      ),
    );
  }
}

/// Small round Nene mark used as the assistant's avatar.
class _NeneMark extends StatelessWidget {
  const _NeneMark({this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: NeneColors.pale,
        shape: BoxShape.circle,
      ),
      child: NeneLogo(size: size * .52, wordmark: false),
    ),
  );
}

class _SessionNote extends StatelessWidget {
  const _SessionNote();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: NeneColors.line.withValues(alpha: .6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Kept only for this session · keep passwords, codes and personal '
          'details out of chat',
          textAlign: TextAlign.center,
          style: TextStyle(color: NeneColors.muted, fontSize: 12),
        ),
      ),
    ),
  );
}

class _CustomerBubble extends StatelessWidget {
  const _CustomerBubble(this.text, {required this.maxWidth});
  final String text;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: MergeSemantics(
          child: Semantics(
            label: 'You:',
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 11, 16, 12),
              decoration: const BoxDecoration(
                color: NeneColors.action,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                  bottomLeft: Radius.circular(20),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Text(
                text,
                style: const TextStyle(color: Colors.white, height: 1.4),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble(
    this.message, {
    required this.maxWidth,
    required this.busy,
    required this.onAction,
  });
  final AssistantMessage message;
  final double maxWidth;
  final bool busy;
  final ValueChanged<AssistantAction> onAction;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _NeneMark(),
        const SizedBox(width: 8),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MergeSemantics(
                  child: Semantics(
                    label: 'Nene:',
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 11, 16, 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: NeneColors.line),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(6),
                          topRight: Radius.circular(20),
                          bottomLeft: Radius.circular(20),
                          bottomRight: Radius.circular(20),
                        ),
                      ),
                      child: Text(
                        message.text,
                        style: const TextStyle(height: 1.45),
                      ),
                    ),
                  ),
                ),
                for (final action in message.actions)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _ActionLink(
                      action,
                      onTap: busy ? null : () => onAction(action),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// An allowlisted destination the reply offers. It only opens a screen.
class _ActionLink extends StatelessWidget {
  const _ActionLink(this.action, {required this.onTap});
  final AssistantAction action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      child: Material(
        color: enabled ? NeneColors.pale : NeneColors.line,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    _activityIcon(action.activity),
                    size: 20,
                    color: enabled ? NeneColors.action : NeneColors.muted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    action.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: enabled ? NeneColors.deep : NeneColors.muted,
                      fontFeatures: neneTabularFigures,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: enabled ? NeneColors.action : NeneColors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: NeneColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: NeneColors.pale,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: NeneColors.action),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = onTap == null ? NeneColors.muted : NeneColors.action;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Material(
        color: Colors.white,
        shape: const StadiumBorder(side: BorderSide(color: NeneColors.line)),
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: onTap == null ? NeneColors.muted : NeneColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Three pulsing dots in a reply bubble while an answer is pending.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse
        ..stop()
        ..value = .5;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Row(
      children: [
        const _NeneMark(),
        const SizedBox(width: 8),
        Semantics(
          label: 'Getting an answer',
          liveRegion: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: NeneColors.line),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(20),
              ),
            ),
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) const SizedBox(width: 5),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: NeneColors.brand.withValues(
                          alpha:
                              .35 +
                              .65 *
                                  (math.sin(
                                        (_pulse.value - i * .18) * 2 * math.pi,
                                      ) +
                                      1) /
                                  2,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard(this.message, {required this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 14, left: 40),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
        decoration: BoxDecoration(
          color: _errorTint,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, color: error),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(message, style: const TextStyle(height: 1.4)),
                  ),
                  TextButton.icon(
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Retry answer'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
