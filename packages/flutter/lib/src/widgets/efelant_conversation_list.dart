import 'package:flutter/material.dart';

class EfelantConversationList extends StatelessWidget {
  const EfelantConversationList({
    super.key,
    this.tenantId,
    this.children = const [],
  });

  final String? tenantId;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: tenantId ?? 'efelant-conversations',
      child: ListView(children: children),
    );
  }
}
