import 'credential_store_stub.dart'
    if (dart.library.io) 'credential_store_io.dart'
    if (dart.library.js_interop) 'credential_store_web.dart'
    as impl;

/// Session + device identity for this client.
///
/// Native: durable secure storage (one device per install).
/// Web: `sessionStorage` so each tab is its own device. localStorage would
/// bind the first logged-in user to the browser and reject the second
/// ("device belongs to another user").
abstract class CredentialStore {
  factory CredentialStore() => impl.createCredentialStore();

  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}
