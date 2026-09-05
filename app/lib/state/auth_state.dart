import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../database/auth_repository.dart';
import '../database/credential_store.dart';
import '../database/e2ee_service.dart';
import '../database/postgres_client.dart';
import '../models/models.dart';

class AuthState extends ChangeNotifier {
  AuthState({
    required PostgresClient client,
    required AuthRepository auth,
    required E2eeService e2ee,
  }) : _client = client,
       _auth = auth,
       _e2ee = e2ee;

  final PostgresClient _client;
  final AuthRepository _auth;
  final E2eeService _e2ee;
  final _storage = CredentialStore();

  AuthSession? session;
  DeviceInfo? device;
  String? error;
  bool busy = false;
  bool ready = false;
  String? deviceId;
  String hostOverride = '';

  static const _tokenKey = 'efelant.session_token';
  static const _deviceKey = 'efelant.device_id';

  Future<void> bootstrap() async {
    deviceId = await _storage.read(_deviceKey);
    if (deviceId == null || deviceId!.isEmpty) {
      await _rotateDevice();
    }

    final prefs = await SharedPreferences.getInstance();
    hostOverride = prefs.getString(efelantHostPrefKey) ?? '';
    _client.updateConfig(applyHostOverride(EfelantConfig.resolve(), hostOverride));

    try {
      await _client.connect();
    } catch (err) {
      error = err.toString();
      ready = true;
      notifyListeners();
      return;
    }

    final token = await _storage.read(_tokenKey);
    if (token != null && token.isNotEmpty) {
      try {
        session = await _auth.resume(token);
        device = await _auth.currentDevice();
        await _publishKeys();
      } catch (_) {
        await _storage.delete(_tokenKey);
        session = null;
      }
    }
    ready = true;
    notifyListeners();
  }

  Future<void> login(String username, String password) async {
    await _run(() async {
      try {
        await _loginOnce(username, password);
      } on EfelantException catch (err) {
        if (!_isForeignDevice(err)) {
          rethrow;
        }
        await _rotateDevice();
        await _loginOnce(username, password);
      }
    });
  }

  Future<void> register({
    required String username,
    required String displayName,
    required String password,
  }) async {
    await _run(() async {
      try {
        await _registerOnce(
          username: username,
          displayName: displayName,
          password: password,
        );
      } on EfelantException catch (err) {
        if (!_isForeignDevice(err)) {
          rethrow;
        }
        await _rotateDevice();
        await _registerOnce(
          username: username,
          displayName: displayName,
          password: password,
        );
      }
    });
  }

  Future<void> resumeAfterReconnect() async {
    final token = await _storage.read(_tokenKey);
    if (token == null || token.isEmpty) {
      return;
    }
    session = await _auth.resume(token);
    device = await _auth.currentDevice();
    await _publishKeys();
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await _auth.logout();
    } catch (_) {}
    await _storage.delete(_tokenKey);
    session = null;
    device = null;
    notifyListeners();
  }

  Future<void> _storeSession(AuthSession result) async {
    final token = result.sessionToken;
    if (token != null) {
      await _storage.write(_tokenKey, token);
    }
    session = result;
    device = await _auth.currentDevice();
    await _publishKeys();
  }

  Future<void> _loginOnce(String username, String password) async {
    final result = await _auth.login(
      username: username.trim(),
      password: password,
      deviceId: deviceId!,
      deviceName: _deviceName(),
      platform: _platformName(),
    );
    await _storeSession(result);
  }

  Future<void> _registerOnce({
    required String username,
    required String displayName,
    required String password,
  }) async {
    final result = await _auth.register(
      username: username.trim(),
      displayName: displayName.trim(),
      password: password,
      deviceId: deviceId!,
      deviceName: _deviceName(),
      platform: _platformName(),
    );
    await _storeSession(result);
  }

  Future<void> _rotateDevice() async {
    deviceId = const Uuid().v7();
    await _storage.write(_deviceKey, deviceId!);
    await _storage.delete(_tokenKey);
  }

  bool _isForeignDevice(EfelantException err) {
    return err.message.toLowerCase().contains('device belongs to another user');
  }

  Future<void> _publishKeys() async {
    if (deviceId == null) {
      return;
    }
    await _e2ee.loadOrCreate(deviceId!);
    if (session != null) {
      _e2ee.bindUser(session!.userId);
    }
    if (_e2ee.publicKeyBytes != null) {
      await _auth.publishDeviceKey(_e2ee.publicKeyBytes!);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (err) {
      error = err is EfelantException ? err.message : err.toString();
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  String _deviceName() => '${_platformName()} device';

  String _platformName() => kIsWeb ? 'web' : defaultTargetPlatform.name;

  String? get publicKeyFingerprint {
    final bytes = _e2ee.publicKeyBytes;
    if (bytes == null) {
      return null;
    }
    return bytes
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(':');
  }

  EfelantConfig get config => _client.config;

  String get hostLabel {
    if (hostOverride.isNotEmpty) {
      return hostOverride;
    }
    return hostEndpointLabel(config, isWeb: kIsWeb);
  }

  Future<void> setHost(String raw) async {
    final next = raw.trim();
    final prefs = await SharedPreferences.getInstance();
    if (next.isEmpty) {
      await prefs.remove(efelantHostPrefKey);
    } else {
      await prefs.setString(efelantHostPrefKey, next);
    }
    hostOverride = next;
    if (session != null) {
      await logout();
    }
    await _client.close();
    _client.updateConfig(applyHostOverride(EfelantConfig.resolve(), next));
    try {
      await _client.connect();
      error = null;
    } catch (err) {
      error = err is EfelantException ? err.message : err.toString();
    }
    notifyListeners();
  }
}
