import 'package:web/web.dart' as web;

import 'credential_store.dart';

CredentialStore createCredentialStore() => WebCredentialStore();

class WebCredentialStore implements CredentialStore {
  @override
  Future<String?> read(String key) async {
    final value = web.window.sessionStorage.getItem(key);
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    web.window.sessionStorage.setItem(key, value);
  }

  @override
  Future<void> delete(String key) async {
    web.window.sessionStorage.removeItem(key);
  }
}
