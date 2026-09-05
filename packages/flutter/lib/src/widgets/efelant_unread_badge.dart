import 'package:flutter/material.dart';

class EfelantUnreadBadge extends StatelessWidget {
  const EfelantUnreadBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) {
      return const SizedBox.shrink();
    }
    return Badge(label: Text(count > 99 ? '99+' : '$count'));
  }
}
