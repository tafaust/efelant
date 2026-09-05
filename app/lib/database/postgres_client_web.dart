import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config.dart';
import '../models/models.dart';
import 'postgres_client.dart';

PostgresClient createPostgresClient({
  required EfelantConfig config,
  required String deviceId,
}) {
  return WebPostgresClient(config: config, deviceId: deviceId);
}

class WebPostgresClient implements PostgresClient {
  WebPostgresClient({required EfelantConfig config, required String deviceId})
    : _config = config,
      _deviceId = deviceId;

  EfelantConfig _config;
  final String _deviceId;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _pending = <int, Completer<SqlRows>>{};
  int _nextId = 1;
  bool _closedByUser = false;
  bool _connecting = false;
  int _attempts = 0;
  Timer? _reconnectTimer;

  @override
  NotificationHandler? onNotification;
  @override
  void Function()? onReady;
  @override
  void Function(Object error)? onError;

  @override
  EfelantConfig get config => _config;

  @override
  void updateConfig(EfelantConfig config) {
    _config = config;
  }

  @override
  Future<void> connect() async {
    _closedByUser = false;
    await _open();
  }

  @override
  Future<void> close() async {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(EfelantException('connection closed'));
      }
    }
    _pending.clear();
  }

  @override
  Future<void> reconnectNow() async {
    _attempts = 0;
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
    await _open();
  }

  @override
  Future<SqlRows> query(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) async {
    await _require();
    final id = _nextId++;
    final completer = Completer<SqlRows>();
    _pending[id] = completer;
    _channel!.sink.add(
      jsonEncode({
        'id': id,
        'sql': sql,
        'params': encodeParams(parameters),
      }),
    );
    return completer.future.timeout(
      timeout ?? const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw EfelantException('query timed out');
      },
    );
  }

  Future<void> _require() async {
    if (_channel != null) {
      return;
    }
    await _open();
    if (_channel == null) {
      throw EfelantException('not connected to PostgreSQL gateway');
    }
  }

  Future<void> _open() async {
    if (_connecting || _closedByUser) {
      return;
    }
    _connecting = true;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(_config.wsUrl));
      await channel.ready;
      _channel = channel;
      await _sub?.cancel();
      _sub = channel.stream.listen(
        _onMessage,
        onError: (Object error) {
          onError?.call(error);
          unawaited(_scheduleReconnect());
        },
        onDone: () {
          if (!_closedByUser) {
            unawaited(_scheduleReconnect());
          }
        },
      );
      _attempts = 0;
      channel.sink.add(
        jsonEncode({
          'id': 0,
          'sql':
              "SELECT set_config('application_name', @name::text, false)",
          'params': {'name': 'efelant/web/$_deviceId'},
        }),
      );
      channel.sink.add(
        jsonEncode({'id': 0, 'listen': 'efelant_events'}),
      );
      onReady?.call();
    } catch (error) {
      onError?.call(error);
      await _scheduleReconnect();
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  void _onMessage(dynamic raw) {
    final decoded = jsonDecode(raw as String);
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    if (decoded['notify'] is Map) {
      final payload = (decoded['notify'] as Map)['payload']?.toString();
      if (payload != null) {
        onNotification?.call(payload);
      }
      return;
    }
    final id = decoded['id'];
    if (id is! int) {
      return;
    }
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) {
      return;
    }
    if (decoded['error'] != null) {
      completer.completeError(EfelantException(decoded['error'].toString()));
      return;
    }
    final rows = <Map<String, Object?>>[];
    for (final row in (decoded['rows'] as List? ?? const [])) {
      if (row is Map) {
        rows.add(decodeRow(Map<String, dynamic>.from(row)));
      }
    }
    completer.complete(rows);
  }

  Future<void> _scheduleReconnect() async {
    _channel = null;
    if (_closedByUser || _reconnectTimer != null) {
      return;
    }
    _attempts += 1;
    if (_attempts > 20) {
      onError?.call(EfelantException('gave up reconnecting after 20 attempts'));
      return;
    }
    final delayMs = (500 * (1 << (_attempts - 1).clamp(0, 6))).clamp(500, 30000);
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      _reconnectTimer = null;
      try {
        await _open();
      } catch (_) {}
    });
  }
}

Map<String, Object?> encodeParams(Map<String, Object?> parameters) {
  return {
    for (final entry in parameters.entries)
      entry.key: encodeValue(entry.value),
  };
}

Object? encodeValue(Object? value) {
  if (value is List<int> && value is! String) {
    return {'__bytea': base64Encode(value)};
  }
  if (value is DateTime) {
    return value.toUtc().toIso8601String();
  }
  return value;
}

Map<String, Object?> decodeRow(Map<String, dynamic> row) {
  return {for (final entry in row.entries) entry.key: decodeValue(entry.value)};
}

Object? decodeValue(Object? value) {
  if (value is Map && value['__bytea'] != null) {
    return base64Decode(value['__bytea'].toString());
  }
  return value;
}
