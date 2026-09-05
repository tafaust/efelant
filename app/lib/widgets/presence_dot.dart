import 'package:flutter/material.dart';

import '../app/theme.dart';

class PresenceDot extends StatelessWidget {
  const PresenceDot({super.key, required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: online ? const Color(0xFF51CF66) : EfelantColors.navyLight,
        shape: BoxShape.circle,
        border: Border.all(color: EfelantColors.navy, width: 1),
      ),
    );
  }
}
