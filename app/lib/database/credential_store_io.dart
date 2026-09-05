import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'credential_store.dart';

CredentialStore createCredentialStore() => IoCredentialStore();

class IoCredentialStore implements CredentialStore {
  final _secure = const FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    final fromSecure = await _secure.read(key: key);
    if (fromSecure != null && fromSecure.isNotEmpty) {
      return fromSecure;
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    await _secure.write(key: key, value: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  Future<void> delete(String key) async {
    await _secure.delete(key: key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}
