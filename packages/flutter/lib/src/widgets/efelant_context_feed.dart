import 'package:flutter/material.dart';

import '../models.dart';
import 'efelant_status_event.dart';

class EfelantContextFeed extends StatelessWidget {
  const EfelantContextFeed({
    super.key,
    required this.tenantId,
    required this.context,
    this.events = const [],
  });

  final String tenantId;
  final EfelantContext context;
  final List<EfelantTimelineEvent> events;

  @override
  Widget build(BuildContext buildContext) {
    if (events.isEmpty) {
      return const SizedBox.shrink();
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: events.length,
      itemBuilder: (context, index) {
        final event = events[index];
        if (event.type == 'status.changed') {
          return EfelantStatusEvent(
            status: event.payload['status']?.toString() ?? event.type,
            message: event.payload['message']?.toString(),
          );
        }
        return ListTile(
          dense: true,
          title: Text(event.type),
          subtitle: Text(event.payload['message']?.toString() ?? ''),
        );
      },
    );
  }
}
