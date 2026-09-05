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

/// SharedPreferences key for the user-typed host override.
const efelantHostPrefKey = 'efelant.host';

class ParsedEfelantHost {
  const ParsedEfelantHost({
    required this.host,
    required this.port,
    required this.wsUrl,
  });

  final String host;
  final int port;
  final String wsUrl;
}

/// Turn a typed host into Postgres + WebSocket endpoints.
///
/// Empty input is not parsed; call [applyHostOverride] instead.
ParsedEfelantHost parseEfelantHost(String raw) {
  final trimmed = raw.trim();
  if (trimmed.contains('://')) {
    return _fromUri(Uri.parse(trimmed), implied: false);
  }
  return _fromUri(Uri.parse('https://$trimmed'), implied: true);
}

EfelantConfig applyHostOverride(EfelantConfig base, String raw) {
  if (raw.trim().isEmpty) {
    return base;
  }
  final parsed = parseEfelantHost(raw);
  return base.copyWith(
    host: parsed.host,
    port: parsed.port,
    wsUrl: parsed.wsUrl,
  );
}

String hostEndpointLabel(EfelantConfig config, {required bool isWeb}) {
  if (isWeb) {
    return config.wsUrl;
  }
  return '${config.host}:${config.port}';
}

ParsedEfelantHost _fromUri(Uri uri, {required bool implied}) {
  final host = uri.host.isEmpty ? 'localhost' : uri.host;
  final scheme = uri.scheme.toLowerCase();
  final explicitPort = uri.hasPort ? uri.port : null;
  final postgresPort = switch (explicitPort) {
    80 || 443 || 8080 || 5433 => 5432,
    int port => port,
    null => 5432,
  };
  return ParsedEfelantHost(
    host: host,
    port: postgresPort,
    wsUrl: implied
        ? _impliedWebsocket(host, explicitPort)
        : _websocketUrl(uri, host, scheme, explicitPort),
  );
}

String _websocketUrl(Uri uri, String host, String scheme, int? port) {
  if (scheme == 'ws' || scheme == 'wss') {
    return uri.toString();
  }
  if (scheme == 'http' || scheme == 'https') {
    final ws = scheme == 'https' ? 'wss' : 'ws';
    final path = uri.path.isEmpty || uri.path == '/' ? '/ws' : uri.path;
    final authority = _wsAuthority(host, port);
    return '$ws://$authority$path${uri.hasQuery ? '?${uri.query}' : ''}';
  }
  return _impliedWebsocket(host, port);
}

String _impliedWebsocket(String host, int? port) {
  return switch (port) {
    80 => 'ws://$host/ws',
    443 => 'wss://$host/ws',
    8080 => 'ws://$host:8080/ws',
    5433 => 'ws://$host:5433',
    _ when _isLoopbackHost(host) => 'ws://$host:5433',
    _ => 'wss://$host/ws',
  };
}

String _wsAuthority(String host, int? port) {
  if (port == null || port == 80 || port == 443) {
    return host;
  }
  return '$host:$port';
}

bool _isLoopbackHost(String host) {
  final value = host.toLowerCase();
  if (value == 'localhost' || value == '::1' || value.endsWith('.local')) {
    return true;
  }
  if (value.startsWith('127.')) {
    return true;
  }
  if (value.startsWith('10.')) {
    return true;
  }
  if (value.startsWith('192.168.')) {
    return true;
  }
  final match = RegExp(r'^172\.(\d+)\.').firstMatch(value);
  if (match != null) {
    final octet = int.tryParse(match.group(1) ?? '');
    return octet != null && octet >= 16 && octet <= 31;
  }
  return false;
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
