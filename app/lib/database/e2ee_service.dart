import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DevicePublicKey {
  const DevicePublicKey({required this.deviceId, required this.publicKey});

  final String deviceId;
  final Uint8List publicKey;
}

class ConversationKeyWrap {
  const ConversationKeyWrap({required this.deviceId, required this.wrappedKey});

  final String deviceId;
  final Uint8List wrappedKey;
}

class E2eeService {
  E2eeService();

  final _storage = const FlutterSecureStorage();
  final _x25519 = X25519();
  final _aes = AesGcm.with256bits();
  final _sha256 = Sha256();

  SimpleKeyPair? _keyPair;
  String? _userId;
  Uint8List? publicKeyBytes;
  final conversationKeys = <String, SecretKey>{};

  void bindUser(String userId) {
    _userId = userId;
  }

  void clearSessionKeys() {
    conversationKeys.clear();
    _userId = null;
  }

  Future<void> loadOrCreate(String deviceId) async {
    final storageKey = 'efelant.x25519.$deviceId';
    final existing = await _storage.read(key: storageKey);
    if (existing != null && existing.isNotEmpty) {
      _keyPair = await _x25519.newKeyPairFromSeed(base64Decode(existing));
    } else {
      _keyPair = await _x25519.newKeyPair();
      final seed = await _keyPair!.extractPrivateKeyBytes();
      await _storage.write(key: storageKey, value: base64Encode(seed));
    }
    final pub = await _keyPair!.extractPublicKey();
    publicKeyBytes = Uint8List.fromList(pub.bytes);
  }

  Future<Uint8List> generateConversationKey() async {
    final key = await _aes.newSecretKey();
    return Uint8List.fromList(await key.extractBytes());
  }

  Future<void> rememberConversationKey(String conversationId, Uint8List raw) async {
    conversationKeys[conversationId] = SecretKey(raw);
    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      return;
    }
    await _storage.write(
      key: _conversationKeyStorageKey(userId, conversationId),
      value: base64Encode(raw),
    );
  }

  Future<bool> restoreConversationKey(String conversationId) async {
    if (conversationKeys.containsKey(conversationId)) {
      return true;
    }
    final userId = _userId;
    if (userId == null || userId.isEmpty) {
      return false;
    }
    final stored = await _storage.read(
      key: _conversationKeyStorageKey(userId, conversationId),
    );
    if (stored == null || stored.isEmpty) {
      return false;
    }
    conversationKeys[conversationId] = SecretKey(base64Decode(stored));
    return true;
  }

  Future<Uint8List?> unwrapWithStoredDevice(
    String deviceId,
    Uint8List wrapped,
  ) async {
    try {
      return await unwrap(wrapped);
    } catch (_) {}
    final stored = await _storage.read(key: 'efelant.x25519.$deviceId');
    if (stored == null || stored.isEmpty) {
      return null;
    }
    final pair = await _x25519.newKeyPairFromSeed(base64Decode(stored));
    try {
      return await _unwrapWithPair(wrapped, pair);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> wrapFor(Uint8List conversationKey, Uint8List recipientPublic) async {
    final eph = await _x25519.newKeyPair();
    final ephPub = await eph.extractPublicKey();
    final shared = await _x25519.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(recipientPublic, type: KeyPairType.x25519),
    );
    final aesKey = await _aesKey(await shared.extractBytes());
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      conversationKey,
      secretKey: aesKey,
      nonce: nonce,
    );
    return Uint8List.fromList([
      1,
      ...ephPub.bytes,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  Future<Uint8List> unwrap(Uint8List wrapped) async {
    if (_keyPair == null) {
      throw StateError('cannot unwrap conversation key');
    }
    return _unwrapWithPair(wrapped, _keyPair!);
  }

  Future<Uint8List> _unwrapWithPair(Uint8List wrapped, SimpleKeyPair pair) async {
    if (wrapped.isEmpty || wrapped.first != 1) {
      throw StateError('cannot unwrap conversation key');
    }
    final ephPub = wrapped.sublist(1, 33);
    final nonce = wrapped.sublist(33, 45);
    final body = wrapped.sublist(45);
    final cipherText = body.sublist(0, body.length - 16);
    final mac = Mac(body.sublist(body.length - 16));
    final shared = await _x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(ephPub, type: KeyPairType.x25519),
    );
    final aesKey = await _aesKey(await shared.extractBytes());
    final clear = await _aes.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: aesKey,
    );
    return Uint8List.fromList(clear);
  }

  String _conversationKeyStorageKey(String userId, String conversationId) {
    return 'efelant.ck.$userId.$conversationId';
  }

  Future<Uint8List> encrypt(String conversationId, List<int> plaintext) async {
    final key = conversationKeys[conversationId];
    if (key == null) {
      throw StateError('missing conversation key');
    }
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(plaintext, secretKey: key, nonce: nonce);
    return Uint8List.fromList([1, ...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List> encryptText(String conversationId, String text) {
    return encrypt(conversationId, utf8.encode(text));
  }

  Future<String?> decryptText(String conversationId, Uint8List? blob) async {
    if (blob == null || blob.isEmpty) {
      return null;
    }
    final bytes = await decrypt(conversationId, blob);
    return utf8.decode(bytes);
  }

  Future<Uint8List> decrypt(String conversationId, Uint8List blob) async {
    final key = conversationKeys[conversationId];
    if (key == null || blob.first != 1) {
      throw StateError('cannot decrypt');
    }
    final nonce = blob.sublist(1, 13);
    final body = blob.sublist(13);
    final cipherText = body.sublist(0, body.length - 16);
    final mac = Mac(body.sublist(body.length - 16));
    final clear = await _aes.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
    );
    return Uint8List.fromList(clear);
  }

  Future<SecretKey> _aesKey(List<int> shared) async {
    final digest = await _sha256.hash(shared);
    return SecretKey(digest.bytes);
  }
}
