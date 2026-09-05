import 'dart:async';
import 'dart:convert';

import '../models/models.dart';
import 'postgres_client.dart';

class RealtimeService {
  RealtimeService(this._client) {
    _client.onNotification = _onPayload;
  }

  final PostgresClient _client;
  final _controller = StreamController<RealtimeEvent>.broadcast();

  Stream<RealtimeEvent> get events => _controller.stream;

  void _onPayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final type = decoded['type']?.toString();
      if (type == null) {
        return;
      }
      _controller.add(RealtimeEvent(type: type, payload: decoded));
    } catch (_) {
      // compact notify payloads only; ignore malformed noise
    }
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
