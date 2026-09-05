import 'package:efelant_flutter/efelant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sync cursor advances after events', () async {
    final client = EfelantClient((sql, {parameters = const {}}) async {
      expect(sql, contains('efelant.sync_events'));
      return [
        {
          'id': 'e1',
          'conversation_id': 'c1',
          'tenant_id': 't1',
          'sequence': 4,
          'type': 'status.changed',
          'actor_id': null,
          'payload': {'status': 'approved'},
          'created_at': '2026-09-05T00:00:00Z',
        },
      ];
    });

    final events = await client.syncEvents(
      const EfelantSyncCursor(conversationId: 'c1', lastSequence: 0),
    );
    expect(events.single.type, 'status.changed');
    expect(client.cursor('c1').lastSequence, 4);
  });
}
