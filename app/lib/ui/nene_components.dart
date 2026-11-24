import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/banking_repository.dart';
import 'nene_brand.dart';

/// Initials avatar used in workspace headers and the profile page.
class NeneAvatar extends StatelessWidget {
  const NeneAvatar(this.name, {super.key, this.size = 44});
  final String name;
  final double size;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    final first = parts.first.characters.first;
    final last = parts.length > 1 ? parts.last.characters.first : '';
    return (first + last).toUpperCase();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: NeneColors.apricotSoft,
        shape: BoxShape.circle,
      ),
      child: Text(
        _initials,
        style: TextStyle(
          fontSize: size * .36,
          fontWeight: FontWeight.w700,
          color: NeneColors.deep,
        ),
      ),
    ),
  );
}

/// Hero card for the customer's primary account, with a hide-balance toggle.
class BalanceCard extends StatelessWidget {
  const BalanceCard({
    super.key,
    required this.account,
    required this.hidden,
    required this.onToggleHidden,
  });

  final BankAccount account;
  final bool hidden;
  final VoidCallback onToggleHidden;

  @override
  Widget build(BuildContext context) {
    const onCard = Colors.white;
    final muted = Colors.white.withValues(alpha: .78);
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 14, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [NeneColors.action, NeneColors.deep],
        ),
        boxShadow: [
          BoxShadow(
            color: NeneColors.deep.withValues(alpha: .18),
            blurRadius: 18,
            spreadRadius: -6,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  account.typeLabel,
                  style: const TextStyle(
                    color: onCard,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
              _StatusPill(account.status),
            ],
          ),
          const SizedBox(height: 18),
          Text('Available balance', style: TextStyle(color: muted)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Semantics(
                  label: hidden ? 'Balance hidden' : null,
                  child: Text(
                    hidden ? '•••••• VND' : account.balanceLabel,
                    style: const TextStyle(
                      color: onCard,
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      fontFeatures: neneTabularFigures,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: hidden ? 'Show balance' : 'Hide balance',
                onPressed: onToggleHidden,
                color: onCard,
                icon: Icon(
                  hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Flexible(
                child: Text(
                  account.accountNumber,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: muted,
                    letterSpacing: 1.2,
                    fontFeatures: neneTabularFigures,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy account number',
                visualDensity: VisualDensity.compact,
                color: muted,
                iconSize: 18,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: account.accountNumber));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('Account number copied')),
                  );
                },
                icon: const Icon(Icons.copy_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill(this.status);
  final String status;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .16),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      status == 'active' ? 'Active' : status,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// One tile of the home quick-action grid.
class QuickAction extends StatelessWidget {
  const QuickAction({
    super.key,
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
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: onTap == null ? NeneColors.line : NeneColors.pale,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                icon,
                color: onTap == null ? NeneColors.muted : NeneColors.action,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Four-column grid that keeps quick actions aligned on any phone width.
class QuickActionGrid extends StatelessWidget {
  const QuickActionGrid({super.key, required this.actions});
  final List<QuickAction> actions;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: NeneColors.line),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth / 4;
        return Wrap(
          children: [
            for (final action in actions) SizedBox(width: width, child: action),
          ],
        );
      },
    ),
  );
}

/// Section title with an optional trailing action, e.g. "Your accounts".
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.titleMedium),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Tappable callout for important but secondary tasks.
class NeneBanner extends StatelessWidget {
  const NeneBanner({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: NeneColors.apricotSoft,
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: NeneColors.deep),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: const TextStyle(
                      color: NeneColors.muted,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right, color: NeneColors.muted),
          ],
        ),
      ),
    ),
  );
}

/// Large tappable row for a primary workspace task (officer dashboard).
class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
    this.emphasized = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final foreground = emphasized ? Colors.white : NeneColors.ink;
    return Material(
      color: emphasized ? NeneColors.action : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: emphasized
            ? BorderSide.none
            : const BorderSide(color: NeneColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: emphasized
                      ? Colors.white.withValues(alpha: .16)
                      : NeneColors.pale,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  icon,
                  color: emphasized ? Colors.white : NeneColors.action,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      body,
                      style: TextStyle(
                        color: emphasized
                            ? Colors.white.withValues(alpha: .82)
                            : NeneColors.muted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: emphasized ? Colors.white : NeneColors.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
