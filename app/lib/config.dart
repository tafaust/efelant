import 'package:flutter/foundation.dart';

class EfelantConfig {
  const EfelantConfig({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.sslMode,
    required this.wsUrl,
  });

  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final String sslMode;
  final String wsUrl;

  static const defaults = EfelantConfig(
    host: String.fromEnvironment('EFELANT_DB_HOST', defaultValue: 'localhost'),
    port: int.fromEnvironment('EFELANT_DB_PORT', defaultValue: 5432),
    database: String.fromEnvironment(
      'EFELANT_DB_NAME',
      defaultValue: 'efelant',
    ),
    username: String.fromEnvironment(
      'EFELANT_DB_USER',
      defaultValue: 'efelant_app',
    ),
    password: String.fromEnvironment(
      'EFELANT_DB_PASSWORD',
      defaultValue: 'efelant_app_dev_password',
    ),
    sslMode: String.fromEnvironment(
      'EFELANT_DB_SSLMODE',
      defaultValue: 'disable',
    ),
    wsUrl: String.fromEnvironment('EFELANT_WS_URL'),
  );

  /// Native clients use compile-time defaults. Web prefers same-origin `/ws`
  /// so one nginx/Caddy host can serve the UI and the Postgres adapter.
  static EfelantConfig resolve({Uri? page}) {
    final wsUrl = websocketUrlFor(
      override: defaults.wsUrl,
      isWeb: kIsWeb,
      page: page ?? Uri.base,
    );
    return defaults.copyWith(wsUrl: wsUrl);
  }

  EfelantConfig copyWith({
    String? host,
    int? port,
    String? database,
    String? username,
    String? password,
    String? sslMode,
    String? wsUrl,
  }) {
    return EfelantConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      database: database ?? this.database,
      username: username ?? this.username,
      password: password ?? this.password,
      sslMode: sslMode ?? this.sslMode,
      wsUrl: wsUrl ?? this.wsUrl,
    );
  }
}

/// Resolves the browser WebSocket URL.
///
/// A non-empty [override] always wins (`--dart-define=EFELANT_WS_URL=`).
/// On web, published HTTP(S) ports use same-origin `/ws`. Flutter's debug
/// web-server uses a random port with no proxy, so it falls back to the
/// local gateway on :5433.
String websocketUrlFor({
  required String override,
  required bool isWeb,
  required Uri page,
}) {
  if (override.isNotEmpty) {
    return override;
  }
  if (isWeb && _sameOriginProxy(page)) {
    final scheme = page.scheme == 'https' ? 'wss' : 'ws';
    final port = page.hasPort ? ':${page.port}' : '';
    return '$scheme://${page.host}$port/ws';
  }
  return 'ws://localhost:5433';
}

bool _sameOriginProxy(Uri page) {
  if (!page.hasPort) {
    return true;
  }
  return switch (page.port) {
    80 || 443 || 8080 => true,
    _ => false,
  };
}
