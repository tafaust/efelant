import 'package:flutter/material.dart';

import '../app/theme.dart';

class TypingIndicator extends StatelessWidget {
  const TypingIndicator({
    super.key,
    required this.visible,
    this.label = 'someone is typing…',
  });

  final bool visible;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          const _Dot(),
          const SizedBox(width: 4),
          const _Dot(),
          const SizedBox(width: 4),
          const _Dot(),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: EfelantColors.accentSoft,
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(
        color: EfelantColors.accent,
        shape: BoxShape.circle,
      ),
    );
  }
}
