import 'dart:typed_data';

import '../models/models.dart';
import 'postgres_client.dart';

class AuthRepository {
  AuthRepository(this._client);

  final PostgresClient _client;

  Future<AuthSession> register({
    required String username,
    required String password,
    required String displayName,
    required String deviceId,
    required String deviceName,
    required String platform,
  }) async {
    final result = await _client.query(
      '''
      SELECT * FROM auth.register(
        @username::text,
        @password::text,
        @display_name::text,
        @device_id::uuid,
        @device_name::text,
        @platform::text
      )
      ''',
      parameters: {
        'username': username,
        'password': password,
        'display_name': displayName,
        'device_id': deviceId,
        'device_name': deviceName,
        'platform': platform,
      },
    );
    return AuthSession.fromRow(result.first);
  }

  Future<AuthSession> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceName,
    required String platform,
  }) async {
    final result = await _client.query(
      '''
      SELECT * FROM auth.login(
        @username::text,
        @password::text,
        @device_id::uuid,
        @device_name::text,
        @platform::text
      )
      ''',
      parameters: {
        'username': username,
        'password': password,
        'device_id': deviceId,
        'device_name': deviceName,
        'platform': platform,
      },
    );
    return AuthSession.fromRow(result.first);
  }

  Future<AuthSession> resume(String token) async {
    final result = await _client.query(
      'SELECT * FROM auth.resume_session(@token::text)',
      parameters: {'token': token},
    );
    return AuthSession.fromRow(result.first);
  }

  Future<void> logout() async {
    await _client.query('SELECT auth.logout()');
  }

  Future<DeviceInfo?> currentDevice() async {
    final result = await _client.query('SELECT * FROM chat.current_device()');
    if (result.isEmpty) {
      return null;
    }
    return DeviceInfo.fromRow(result.first);
  }

  Future<void> publishDeviceKey(List<int> publicKey) async {
    await _client.query(
      'SELECT auth.publish_device_key(@key::bytea)',
      parameters: {'key': Uint8List.fromList(publicKey)},
    );
  }

  Future<String?> currentTenantId() async {
    final result = await _client.query('SELECT auth.current_tenant_id() AS id');
    if (result.isEmpty) {
      return null;
    }
    return result.first['id']?.toString();
  }
}
