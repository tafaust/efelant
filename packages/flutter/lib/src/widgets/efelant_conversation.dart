import 'package:flutter/material.dart';

import '../models.dart';

class EfelantConversation extends StatelessWidget {
  const EfelantConversation({
    super.key,
    required this.tenantId,
    this.conversationId,
    this.context,
    this.child,
  });

  final String tenantId;
  final String? conversationId;
  final EfelantContext? context;
  final Widget? child;

  @override
  Widget build(BuildContext buildContext) {
    return Semantics(
      container: true,
      identifier:
          conversationId ?? '${context?.type}:${context?.externalId}:$tenantId',
      child: child ?? const SizedBox.shrink(),
    );
  }
}
