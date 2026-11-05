import 'package:flutter/material.dart';
import '../assistant_controller.dart';
import '../data/assistant_api.dart';
import 'nene_brand.dart';

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
      return SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(24),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Nene assistant',
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Clear conversation',
                            onPressed: chat.clear,
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      const Text(
                        'Ask about an activity in English or Vietnamese. This assistant understands a limited set of requests and replies in English. Keep passwords, codes and personal details out of chat.',
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final prompt in [
                            'History last month',
                            'Transfer money',
                            'Pay my bills',
                          ])
                            OutlinedButton(
                              onPressed: chat.busy ? null : () => _send(prompt),
                              child: Text(prompt),
                            ),
                        ],
                      ),
                      if (chat.messages.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text(
                            'Ask a question to find the right screen. You review and confirm any transaction in its usual flow. This conversation is kept only for your current session.',
                          ),
                        ),
                      for (final message in chat.messages)
                        Align(
                          alignment: message.isCustomer
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(top: 12),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: message.isCustomer
                                  ? NeneColors.pale
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: NeneColors.border),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  message.isCustomer ? 'You' : 'Nene',
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                                const SizedBox(height: 6),
                                Semantics(
                                  liveRegion: !message.isCustomer,
                                  child: Text(message.text),
                                ),
                                for (final action in message.actions)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: OutlinedButton.icon(
                                      onPressed: chat.busy
                                          ? null
                                          : () => widget.onAction(action),
                                      icon: const Icon(Icons.arrow_forward),
                                      label: Text(action.label),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      if (chat.busy)
                        const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: LinearProgressIndicator(
                            semanticsLabel: 'Getting an answer',
                          ),
                        ),
                      if (chat.error != null) ...[
                        const SizedBox(height: 16),
                        Semantics(liveRegion: true, child: Text(chat.error!)),
                        TextButton(
                          onPressed: chat.busy ? null : chat.retry,
                          child: const Text('Retry answer'),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          enabled: !chat.busy,
                          maxLength: 500,
                          minLines: 1,
                          maxLines: 3,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            labelText: 'Ask Nene',
                            hintText: 'Show history for 2026-10',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Send message',
                        onPressed: chat.busy ? null : () => _send(),
                        icon: const Icon(Icons.send),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
