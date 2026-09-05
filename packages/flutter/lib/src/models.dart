class EfelantContext {
  const EfelantContext({
    required this.type,
    required this.externalId,
    this.metadata = const {},
  });

  final String type;
  final String externalId;
  final Map<String, Object?> metadata;
}

class EfelantTenant {
  const EfelantTenant({
    required this.id,
    required this.slug,
    required this.name,
    required this.role,
  });

  final String id;
  final String slug;
  final String name;
  final String role;
}

class EfelantTimelineEvent {
  const EfelantTimelineEvent({
    required this.id,
    required this.conversationId,
    required this.tenantId,
    required this.sequence,
    required this.type,
    required this.payload,
    required this.createdAt,
    this.actorId,
  });

  final String id;
  final String conversationId;
  final String tenantId;
  final int sequence;
  final String type;
  final String? actorId;
  final Map<String, Object?> payload;
  final DateTime createdAt;

  factory EfelantTimelineEvent.fromRow(Map<String, Object?> row) {
    return EfelantTimelineEvent(
      id: row['id'].toString(),
      conversationId: row['conversation_id'].toString(),
      tenantId: row['tenant_id'].toString(),
      sequence: (row['sequence'] as num).toInt(),
      type: row['type'].toString(),
      actorId: row['actor_id']?.toString(),
      payload: Map<String, Object?>.from(
        (row['payload'] as Map?) ?? const {},
      ),
      createdAt: DateTime.parse(row['created_at'].toString()),
    );
  }
}

class EfelantSyncCursor {
  const EfelantSyncCursor({
    required this.conversationId,
    required this.lastSequence,
  });

  final String conversationId;
  final int lastSequence;
}

typedef EfelantQuery =
    Future<List<Map<String, Object?>>> Function(
      String sql, {
      Map<String, Object?> parameters,
    });
