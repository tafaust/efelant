// GENERATED from Stencil component contracts. Do not edit.
// Official Stencil outputs are React / Angular / Vue / Ember.
// Flutter has no first-party target; this repo emits Dart facades
// that wrap the native widgets and keep the same public props.
import 'package:flutter/material.dart';

import '../models.dart';
import '../widgets/efelant_composer.dart';
import '../widgets/efelant_context_feed.dart';
import '../widgets/efelant_conversation.dart';
import '../widgets/efelant_conversation_list.dart';
import '../widgets/efelant_status_event.dart';
import '../widgets/efelant_unread_badge.dart';

class EfelantComposerElement extends StatelessWidget {
  const EfelantComposerElement({
    super.key,
    required this.onSend,
    this.placeholder = 'Message',
    this.disabled = false,
  });
  final ValueChanged<String> onSend;
  final String placeholder;
  final bool disabled;
  @override
  Widget build(BuildContext context) {
    return EfelantComposer(onSend: onSend, enabled: !disabled, placeholder: placeholder);
  }
}

class EfelantContextFeedElement extends StatelessWidget {
  const EfelantContextFeedElement({
    super.key,
    required this.tenantId,
    required this.contextType,
    required this.externalId,
    this.events = const [],
  });
  final String tenantId;
  final String contextType;
  final String externalId;
  final List<EfelantTimelineEvent> events;
  @override
  Widget build(BuildContext context) {
    return EfelantContextFeed(
      tenantId: tenantId,
      context: EfelantContext(type: contextType, externalId: externalId),
      events: events,
    );
  }
}

/// Facade for the efelant-conversation Stencil element.
class EfelantConversationElement extends StatelessWidget {
  const EfelantConversationElement({
    super.key,
    required this.tenantId,
    this.conversationId,
    this.contextType,
    this.externalId,
    this.child,
  });
  final String tenantId;
  final String? conversationId;
  final String? contextType;
  final String? externalId;
  final Widget? child;
  @override
  Widget build(BuildContext context) {
    return EfelantConversation(
      tenantId: tenantId,
      conversationId: conversationId,
      context: contextType == null || externalId == null
          ? null
          : EfelantContext(type: contextType!, externalId: externalId!),
      child: child,
    );
  }
}

class EfelantConversationListElement extends StatelessWidget {
  const EfelantConversationListElement({super.key, this.tenantId, this.children = const []});
  final String? tenantId;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return EfelantConversationList(tenantId: tenantId, children: children);
  }
}

class EfelantStatusEventElement extends StatelessWidget {
  const EfelantStatusEventElement({super.key, this.status = '', this.message = ''});
  final String status;
  final String message;
  @override
  Widget build(BuildContext context) {
    return EfelantStatusEvent(status: status, message: message);
  }
}

class EfelantUnreadBadgeElement extends StatelessWidget {
  const EfelantUnreadBadgeElement({super.key, this.count = 0});
  final int count;
  @override
  Widget build(BuildContext context) {
    return EfelantUnreadBadge(count: count);
  }
}
