import 'models.dart';

/// SQL-function client. Host apps supply a query runner that already talks
/// to PostgreSQL or to the browser gateway.
class EfelantClient {
  EfelantClient(this.query);

  final EfelantQuery query;
  final Map<String, int> _sequences = {};

  Future<String?> currentTenantId() async {
    final rows = await query('SELECT auth.current_tenant_id() AS id');
    return rows.first['id']?.toString();
  }

  Future<List<EfelantTenant>> listTenants() async {
    final rows = await query('SELECT id, slug, name, role FROM auth.list_tenants()');
    return [
      for (final row in rows)
        EfelantTenant(
          id: row['id'].toString(),
          slug: row['slug'].toString(),
          name: row['name'].toString(),
          role: row['role'].toString(),
        ),
    ];
  }

  Future<void> selectTenant(String tenantId) async {
    await query(
      'SELECT auth.select_tenant(@tenant_id::uuid)',
      parameters: {'tenant_id': tenantId},
    );
  }

  Future<String> openContext({
    required String tenantId,
    required EfelantContext context,
  }) async {
    final rows = await query(
      '''
      SELECT conversation_id FROM efelant.open_context(
        @tenant_id::uuid, @type::text, @external_id::text, @metadata::jsonb
      )
      ''',
      parameters: {
        'tenant_id': tenantId,
        'type': context.type,
        'external_id': context.externalId,
        'metadata': context.metadata,
      },
    );
    return rows.first['conversation_id'].toString();
  }

  Future<List<EfelantTimelineEvent>> syncEvents(EfelantSyncCursor cursor) async {
    final rows = await query(
      'SELECT * FROM efelant.sync_events(@conversation_id::uuid, @after::bigint)',
      parameters: {
        'conversation_id': cursor.conversationId,
        'after': cursor.lastSequence,
      },
    );
    final events = [for (final row in rows) EfelantTimelineEvent.fromRow(row)];
    if (events.isNotEmpty) {
      _sequences[cursor.conversationId] = events.last.sequence;
    }
    return events;
  }

  EfelantSyncCursor cursor(String conversationId) {
    return EfelantSyncCursor(
      conversationId: conversationId,
      lastSequence: _sequences[conversationId] ?? 0,
    );
  }
}
