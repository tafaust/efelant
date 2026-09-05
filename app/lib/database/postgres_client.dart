import '../config.dart';
import 'postgres_client_stub.dart'
    if (dart.library.io) 'postgres_client_io.dart'
    if (dart.library.js_interop) 'postgres_client_web.dart'
    as impl;

typedef NotificationHandler = void Function(String payload);
typedef SqlRows = List<Map<String, Object?>>;

abstract class PostgresClient {
  factory PostgresClient({
    required EfelantConfig config,
    required String deviceId,
  }) {
    return impl.createPostgresClient(config: config, deviceId: deviceId);
  }

  EfelantConfig get config;
  void updateConfig(EfelantConfig config);

  NotificationHandler? onNotification;
  void Function()? onReady;
  void Function(Object error)? onError;

  Future<void> connect();
  Future<void> close();
  Future<void> reconnectNow();
  Future<SqlRows> query(
    String sql, {
    Map<String, Object?> parameters,
    Duration? timeout,
  });
}
