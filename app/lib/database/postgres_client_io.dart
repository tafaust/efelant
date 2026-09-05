import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart';

import '../config.dart';
import '../models/models.dart';
import 'postgres_client.dart';

PostgresClient createPostgresClient({
  required EfelantConfig config,
  required String deviceId,
}) {
  return IoPostgresClient(config: config, deviceId: deviceId);
}

class IoPostgresClient implements PostgresClient {
  IoPostgresClient({required EfelantConfig config, required String deviceId})
    : _config = config,
      _deviceId = deviceId;

  EfelantConfig _config;
  final String _deviceId;
  Connection? _connection;
  StreamSubscription<String>? _listenSub;
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

  bool get _isOpen => _connection != null && _connection!.isOpen;

  @override
  Future<void> connect() async {
    _closedByUser = false;
    await _open();
  }

  @override
  Future<void> close() async {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    await _listenSub?.cancel();
    _listenSub = null;
    await _connection?.close();
    _connection = null;
  }

  @override
  Future<void> reconnectNow() async {
    _attempts = 0;
    await _listenSub?.cancel();
    _listenSub = null;
    await _connection?.close();
    _connection = null;
    await _open();
  }

  @override
  Future<SqlRows> query(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) async {
    final conn = await _require();
    try {
      final result = await conn
          .execute(Sql.named(sql), parameters: parameters)
          .timeout(timeout ?? const Duration(seconds: 30));
      return [for (final row in result) row.toColumnMap()];
    } on ServerException catch (error) {
      throw EfelantException(error.message, code: error.code);
    } on TimeoutException {
      throw EfelantException('query timed out');
    } on SocketException {
      unawaited(_scheduleReconnect());
      throw EfelantException('lost database connection');
    }
  }

  Future<Connection> _require() async {
    if (_isOpen) {
      return _connection!;
    }
    await _open();
    if (!_isOpen) {
      throw EfelantException('not connected to PostgreSQL');
    }
    return _connection!;
  }

  Future<void> _open() async {
    if (_connecting || _closedByUser) {
      return;
    }
    _connecting = true;
    try {
      final sslMode = switch (_config.sslMode) {
        'require' => SslMode.require,
        'verifyFull' => SslMode.verifyFull,
        _ => SslMode.disable,
      };
      final connection = await Connection.open(
        Endpoint(
          host: _config.host,
          port: _config.port,
          database: _config.database,
          username: _config.username,
          password: _config.password,
        ),
        settings: ConnectionSettings(
          sslMode: sslMode,
          applicationName: 'efelant/${Platform.operatingSystem}/$_deviceId',
          connectTimeout: const Duration(seconds: 10),
          queryTimeout: const Duration(seconds: 30),
        ),
      );
      await _connection?.close();
      _connection = connection;
      _attempts = 0;
      await _listenSub?.cancel();
      _listenSub = connection.channels['efelant_events'].listen((payload) {
        onNotification?.call(payload);
      });
      connection.closed.then((_) {
        if (!_closedByUser) {
          unawaited(_scheduleReconnect());
        }
      });
      onReady?.call();
    } catch (error) {
      onError?.call(error);
      await _scheduleReconnect();
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  Future<void> _scheduleReconnect() async {
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
