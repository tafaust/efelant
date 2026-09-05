import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../database/chat_repository.dart';
import '../database/e2ee_service.dart';
import '../database/realtime_service.dart';
import '../models/models.dart';

class ChatState extends ChangeNotifier {
  ChatState({
    required ChatRepository chat,
    required E2eeService e2ee,
    required RealtimeService realtime,
    required String Function() currentUserId,
  }) : _chat = chat,
       _e2ee = e2ee,
       _currentUserId = currentUserId {
    _eventSub = realtime.events.listen(_onEvent);
  }

  final ChatRepository _chat;
  final E2eeService _e2ee;
  final String Function() _currentUserId;
  late final StreamSubscription<RealtimeEvent> _eventSub;

  final _uuid = const Uuid();
  final List<RealtimeEvent> _syncQueue = [];

  List<Conversation> conversations = [];
  List<ChatMessage> messages = [];
  List<UserHit> userHits = [];
  String? openConversationId;
  String? peerReadMessageId;
  String? peerDeliveredMessageId;
  String? typingUserId;
  String? typingName;
  IncomingNotice? notice;
  String? error;
  bool syncing = false;
  bool loadingMessages = false;

  Timer? _heartbeat;
  Timer? _typingExpiry;
  Timer? _typingSend;

  String get userId => _currentUserId();

  Future<void> start() async {
    _e2ee.bindUser(userId);
    await goOnline();
    await refreshConversations();
    await _safe(_shareKnownKeys);
  }

  Future<void> goOnline() async {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_safe(_chat.heartbeat));
      unawaited(_safe(_shareKnownKeys));
    });
    await _safe(_chat.heartbeat);
  }

  Future<void> goOffline() async {
    _heartbeat?.cancel();
    await _safe(_chat.setOffline);
  }

  Future<void> stop() async {
    await goOffline();
    conversations = [];
    messages = [];
    openConversationId = null;
    typingUserId = null;
    typingName = null;
    notice = null;
    _e2ee.clearSessionKeys();
  }

  void leaveConversationView(String conversationId) {
    if (openConversationId == conversationId) {
      if (conversationId.isNotEmpty) {
        unawaited(_safe(() => _chat.setTyping(conversationId, false)));
      }
      openConversationId = null;
      typingUserId = null;
      typingName = null;
      notifyListeners();
    }
  }

  void dismissNotice() {
    notice = null;
    notifyListeners();
  }

  Future<void> refreshConversations() async {
    try {
      conversations = await _chat.getConversations();
      _applyPeerReceiptsFromList();
      error = null;
    } on EfelantException catch (err) {
      error = err.message;
    }
    notifyListeners();
  }

  Future<void> loadConversation(String conversationId) async {
    openConversationId = conversationId;
    loadingMessages = true;
    notifyListeners();
    try {
      await _ensureConversationKey(conversationId);
      messages = await _decryptAll(
        conversationId,
        await _chat.getMessages(conversationId),
      );
      await _refreshPeerReceipts(conversationId);
      await _ackIncoming();
      error = null;
    } on EfelantException catch (err) {
      error = err.message;
      messages = [];
    } finally {
      loadingMessages = false;
      notifyListeners();
    }
  }

  Future<void> syncAfterReconnect() async {
    syncing = true;
    notifyListeners();
    try {
      await goOnline();
      await refreshConversations();
      if (openConversationId != null) {
        final cursor = _cursor();
        if (cursor == null) {
          messages = await _decryptAll(
            openConversationId!,
            await _chat.getMessages(openConversationId!),
          );
        } else {
          final newer = await _decryptAll(
            openConversationId!,
            await _chat.getMessagesAfter(openConversationId!, cursor),
          );
          _upsertMessages(newer);
        }
        await _refreshPeerReceipts(openConversationId!);
        await _ackIncoming();
      }
      final queued = List<RealtimeEvent>.from(_syncQueue);
      _syncQueue.clear();
      for (final event in queued) {
        await _applyEvent(event);
      }
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> searchUsers(String query) async {
    if (query.trim().isEmpty) {
      userHits = [];
      notifyListeners();
      return;
    }
    userHits = await _chat.searchUsers(query.trim());
    notifyListeners();
  }

  Future<String> startDirect(String otherUserId) async {
    final id = await _chat.createDirect(otherUserId);
    await _ensureConversationKey(id);
    await refreshConversations();
    return id;
  }

  Future<void> sendText(String text, {String? replyTo}) async {
    final conversationId = openConversationId;
    if (conversationId == null || text.trim().isEmpty) {
      return;
    }
    final clientId = _uuid.v7();
    final optimistic = ChatMessage(
      id: clientId,
      conversationId: conversationId,
      senderId: userId,
      senderUsername: '',
      senderDisplayName: 'you',
      clientId: clientId,
      type: 'text',
      content: text.trim(),
      replyTo: replyTo,
      createdAt: DateTime.now().toUtc(),
      reactions: const [],
      sendState: SendState.sending,
    );
    messages = [...messages, optimistic];
    notifyListeners();

    unawaited(_safe(() => _chat.setTyping(conversationId, false)));
    try {
      await _waitForConversationKey(conversationId);
      if (!_e2ee.conversationKeys.containsKey(conversationId)) {
        throw EfelantException(
          'waiting for the other device to share the conversation key',
        );
      }
      final ciphertext = await _e2ee.encryptText(conversationId, text.trim());
      final saved = await _chat.sendMessage(
        conversationId: conversationId,
        clientId: clientId,
        type: 'text',
        encryptedContent: ciphertext,
        replyTo: replyTo,
      );
      messages = [
        for (final message in messages)
          if (message.clientId == clientId)
            saved.copyWith(sendState: SendState.sent, content: text.trim())
          else
            message,
      ];
      await refreshConversations();
    } catch (err) {
      error = err is EfelantException ? err.message : err.toString();
      messages = [
        for (final message in messages)
          if (message.clientId == clientId)
            message.copyWith(sendState: SendState.failed)
          else
            message,
      ];
    }
    notifyListeners();
  }

  Future<void> retry(ChatMessage message) async {
    if (message.sendState != SendState.failed) {
      return;
    }
    try {
      await _ensureConversationKey(message.conversationId);
      final ciphertext = message.content == null
          ? null
          : await _e2ee.encryptText(message.conversationId, message.content!);
      final saved = await _chat.sendMessage(
        conversationId: message.conversationId,
        clientId: message.clientId,
        type: message.type,
        encryptedContent: ciphertext,
        replyTo: message.replyTo,
      );
      messages = [
        for (final item in messages)
          if (item.clientId == message.clientId)
            saved.copyWith(sendState: SendState.sent, content: message.content)
          else
            item,
      ];
    } catch (_) {}
    notifyListeners();
  }

  Future<void> sendAttachment({
    required String filename,
    required String mimeType,
    required Uint8List data,
  }) async {
    final conversationId = openConversationId;
    if (conversationId == null) {
      return;
    }
    if (data.length > 10 * 1024 * 1024) {
      error = 'attachment exceeds 10 MB';
      notifyListeners();
      return;
    }
    final type = mimeType.startsWith('image/') ? 'image' : 'file';
    final clientId = _uuid.v7();
    await _ensureConversationKey(conversationId);
    final ciphertext = await _e2ee.encryptText(conversationId, filename);
    final encryptedData = await _e2ee.encrypt(conversationId, data);
    final saved = await _chat.sendMessage(
      conversationId: conversationId,
      clientId: clientId,
      type: type,
      encryptedContent: ciphertext,
    );
    await _chat.uploadAttachment(
      messageId: saved.id,
      filename: 'encrypted.bin',
      mimeType: 'application/octet-stream',
      data: encryptedData,
    );
    await loadConversation(conversationId);
  }

  Future<void> edit(ChatMessage message, String content) async {
    final ciphertext = await _e2ee.encryptText(message.conversationId, content);
    await _chat.editEncrypted(message.id, ciphertext);
    await _replaceMessage(message.id);
  }

  Future<void> remove(ChatMessage message) async {
    await _chat.deleteMessage(message.id);
    await _replaceMessage(message.id);
  }

  Future<void> toggleReaction(ChatMessage message, String emoji) async {
    final mine = message.reactions.any(
      (reaction) => reaction.emoji == emoji && reaction.userId == userId,
    );
    if (mine) {
      await _chat.removeReaction(message.id, emoji);
    } else {
      await _chat.addReaction(message.id, emoji);
    }
    await _replaceMessage(message.id);
  }

  void typingChanged(String text) {
    final conversationId = openConversationId;
    if (conversationId == null) {
      return;
    }
    _typingSend?.cancel();
    _typingSend = Timer(const Duration(milliseconds: 250), () {
      unawaited(_safe(() => _chat.setTyping(conversationId, text.isNotEmpty)));
    });
  }

  String get typingLabel {
    final name = typingName;
    if (name != null && name.isNotEmpty) {
      return '$name is typing…';
    }
    return 'someone is typing…';
  }

  ReceiptStatus statusFor(ChatMessage message) {
    return receiptStatus(
      sendState: message.sendState,
      message: message,
      thread: messages,
      deliveredThroughId: peerDeliveredMessageId,
      viewedThroughId: peerReadMessageId,
    );
  }

  Conversation? get currentConversation {
    for (final conversation in conversations) {
      if (conversation.id == openConversationId) {
        return conversation;
      }
    }
    return null;
  }

  ChatMessage? messageById(String id) {
    for (final message in messages) {
      if (message.id == id) {
        return message;
      }
    }
    return null;
  }

  Future<AttachmentPayload> downloadAttachment(String id) async {
    final payload = await _chat.getAttachment(id);
    final conversationId = openConversationId;
    if (conversationId == null) {
      return payload;
    }
    try {
      final clear = await _e2ee.decrypt(
        conversationId,
        Uint8List.fromList(payload.data),
      );
      final message = messageById(payload.messageId);
      final filename =
          (message?.content != null && message!.content!.isNotEmpty)
          ? message.content!
          : payload.filename;
      return AttachmentPayload(
        id: payload.id,
        messageId: payload.messageId,
        filename: filename,
        mimeType: payload.mimeType,
        size: clear.length,
        data: clear,
      );
    } catch (_) {
      return payload;
    }
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _typingExpiry?.cancel();
    _typingSend?.cancel();
    unawaited(_eventSub.cancel());
    super.dispose();
  }

  Future<void> _onEvent(RealtimeEvent event) async {
    if (syncing) {
      _syncQueue.add(event);
      return;
    }
    await _applyEvent(event);
  }

  Future<void> _applyEvent(RealtimeEvent event) async {
    switch (event.type) {
      case 'message.created':
        await _onIncomingMessage(event);
      case 'message.updated':
      case 'message.deleted':
      case 'reaction.updated':
        if (event.messageId != null &&
            event.conversationId == openConversationId) {
          try {
            await _replaceMessage(event.messageId!);
          } on EfelantException catch (err) {
            if (err.code == '42501') {
              messages = [];
              openConversationId = null;
            }
          }
        }
        await refreshConversations();
      case 'conversation.updated':
        await refreshConversations();
        if (event.conversationId == openConversationId) {
          try {
            await _chat.getMessages(event.conversationId!);
          } on EfelantException {
            messages = [];
            openConversationId = null;
            notifyListeners();
          }
        }
      case 'read.updated':
        if (event.conversationId != null && event.userId != userId) {
          peerReadMessageId = event.messageId ?? peerReadMessageId;
          notifyListeners();
        }
        await refreshConversations();
      case 'receipt.updated':
        if (event.conversationId != null && event.userId != userId) {
          peerDeliveredMessageId = event.messageId ?? peerDeliveredMessageId;
          notifyListeners();
        }
      case 'key.wrap.updated':
        if (event.conversationId != null &&
            !_e2ee.conversationKeys.containsKey(event.conversationId)) {
          await _ensureConversationKey(event.conversationId!, share: false);
          if (event.conversationId == openConversationId) {
            messages = await _decryptAll(
              openConversationId!,
              await _chat.getMessages(openConversationId!),
            );
            notifyListeners();
          }
        }
      case 'typing.started':
        if (event.conversationId == openConversationId &&
            event.userId != userId) {
          typingUserId = event.userId;
          typingName = _nameFor(event.userId);
          _typingExpiry?.cancel();
          _typingExpiry = Timer(const Duration(seconds: 4), () {
            typingUserId = null;
            typingName = null;
            notifyListeners();
          });
          notifyListeners();
        }
      case 'typing.stopped':
        if (event.conversationId == openConversationId &&
            event.userId != userId) {
          typingUserId = null;
          typingName = null;
          notifyListeners();
        }
      case 'presence.updated':
        final peerId = event.userId;
        final online = event.online;
        if (peerId != null && online != null) {
          conversations = [
            for (final conversation in conversations)
              conversation.peerUserId == peerId
                  ? conversation.withPeerOnline(online)
                  : conversation,
          ];
          notifyListeners();
        }
        await refreshConversations();
      default:
        break;
    }
  }

  Future<void> _replaceMessage(String messageId) async {
    final incoming = await _chat.getMessage(messageId);
    final decrypted = await _decryptAll(incoming.conversationId, [incoming]);
    _upsertMessages(decrypted);
    notifyListeners();
  }

  Future<void> _ensureConversationKey(
    String conversationId, {
    bool share = true,
  }) async {
    if (_e2ee.conversationKeys.containsKey(conversationId)) {
      if (share) {
        unawaited(_safe(() => _shareMissingWraps(conversationId)));
      }
      return;
    }
    if (await _e2ee.restoreConversationKey(conversationId)) {
      if (share) {
        unawaited(_safe(() => _shareMissingWraps(conversationId)));
      }
      return;
    }
    final wraps = await _chat.getConversationKeyWraps(conversationId);
    for (final wrap in wraps) {
      final raw = await _e2ee.unwrapWithStoredDevice(
        wrap.deviceId,
        wrap.wrappedKey,
      );
      if (raw == null) {
        continue;
      }
      await _e2ee.rememberConversationKey(conversationId, raw);
      if (share) {
        unawaited(_safe(() => _shareMissingWraps(conversationId)));
      }
      return;
    }
    if (wraps.isNotEmpty) {
      return;
    }
    await _establishConversationKey(conversationId);
  }

  Future<void> _shareKnownKeys() async {
    for (final conversation in conversations) {
      await _ensureConversationKey(conversation.id);
    }
    for (final conversationId in _e2ee.conversationKeys.keys.toList()) {
      await _shareMissingWraps(conversationId);
    }
  }

  Future<void> _establishConversationKey(String conversationId) async {
    final existing = await _chat.getConversationKeyWrap(conversationId);
    if (existing != null) {
      await _e2ee.rememberConversationKey(
        conversationId,
        await _e2ee.unwrap(existing),
      );
    } else {
      await _e2ee.rememberConversationKey(
        conversationId,
        await _e2ee.generateConversationKey(),
      );
    }
    await _shareMissingWraps(conversationId);
  }

  Future<void> _shareMissingWraps(String conversationId) async {
    final raw = await _e2ee.conversationKeys[conversationId]?.extractBytes();
    if (raw == null) {
      return;
    }
    final already = {
      for (final wrap in await _chat.getConversationKeyWraps(conversationId))
        wrap.deviceId,
    };
    final devices = await _chat.memberDeviceKeys(conversationId);
    for (final device in devices) {
      if (already.contains(device.deviceId)) {
        continue;
      }
      try {
        final wrapped = await _e2ee.wrapFor(
          Uint8List.fromList(raw),
          device.publicKey,
        );
        await _chat.putConversationKeyWrap(
          conversationId: conversationId,
          deviceId: device.deviceId,
          wrappedKey: wrapped,
        );
      } catch (_) {}
    }
  }

  Future<List<ChatMessage>> _decryptAll(
    String conversationId,
    List<ChatMessage> incoming,
  ) async {
    try {
      await _ensureConversationKey(conversationId);
    } catch (_) {}
    final ciphertexts = await _chat.getCiphertexts(conversationId);
    final hasKey = _e2ee.conversationKeys.containsKey(conversationId);
    final out = <ChatMessage>[];
    for (final message in incoming) {
      final blob = message.encryptedContent ?? ciphertexts[message.id];
      if (blob == null || message.isDeleted) {
        out.add(message);
        continue;
      }
      if (!hasKey) {
        out.add(
          message.copyWith(
            content: 'waiting for another device to share the conversation key',
          ),
        );
        continue;
      }
      try {
        out.add(
          message.copyWith(
            content: await _e2ee.decryptText(conversationId, blob),
          ),
        );
      } catch (_) {
        out.add(message.copyWith(content: 'unable to decrypt'));
      }
    }
    return out;
  }

  void _upsertMessages(List<ChatMessage> incoming) {
    final byId = {for (final message in messages) message.id: message};
    final clientToId = {
      for (final message in messages) message.clientId: message.id,
    };
    for (final message in incoming) {
      final previousId = clientToId[message.clientId];
      if (previousId != null && previousId != message.id) {
        byId.remove(previousId);
      }
      final existing = byId[message.id];
      byId[message.id] = message.copyWith(
        content: message.content ?? existing?.content,
        sendState: SendState.sent,
      );
    }
    messages = byId.values.toList()
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) {
          return byTime;
        }
        return a.id.compareTo(b.id);
      });
  }

  Future<void> _onIncomingMessage(RealtimeEvent event) async {
    final conversationId = event.conversationId;
    if (conversationId == null) {
      await refreshConversations();
      return;
    }
    if (conversationId == openConversationId && event.messageId != null) {
      try {
        await _replaceMessage(event.messageId!);
        await _ackIncoming();
      } on EfelantException catch (err) {
        if (err.code == '42501') {
          messages = [];
          openConversationId = null;
        }
      }
    } else if (event.userId != userId) {
      await refreshConversations();
      _offerNotice(conversationId);
    }
    await refreshConversations();
  }

  void _offerNotice(String conversationId) {
    Conversation? found;
    for (final conversation in conversations) {
      if (conversation.id == conversationId) {
        found = conversation;
        break;
      }
    }
    if (found == null) {
      return;
    }
    notice = IncomingNotice(
      conversationId: found.id,
      title: found.title,
      preview: found.lastMessageEncrypted
          ? 'new message'
          : (found.lastMessageContent ?? 'new message'),
    );
    notifyListeners();
  }

  Future<void> _ackIncoming() async {
    if (openConversationId == null || messages.isEmpty) {
      return;
    }
    ChatMessage? latestIncoming;
    for (final message in messages) {
      if (message.senderId != userId && !message.isDeleted) {
        latestIncoming = message;
      }
    }
    if (latestIncoming == null) {
      return;
    }
    await _safe(
      () => _chat.markDelivered(openConversationId!, latestIncoming!.id),
    );
    await _safe(() => _chat.markRead(openConversationId!, latestIncoming!.id));
  }

  Future<void> _refreshPeerReceipts(String conversationId) async {
    try {
      final receipts = await _chat.getPeerReceipts(conversationId);
      peerDeliveredMessageId = receipts.deliveredId ?? peerDeliveredMessageId;
      peerReadMessageId = receipts.readId ?? peerReadMessageId;
    } catch (_) {}
  }

  void _applyPeerReceiptsFromList() {
    final conversation = currentConversation;
    if (conversation == null) {
      return;
    }
    peerReadMessageId = conversation.peerLastReadMessageId ?? peerReadMessageId;
    peerDeliveredMessageId =
        conversation.peerLastDeliveredMessageId ?? peerDeliveredMessageId;
  }

  String? _nameFor(String? userId) {
    if (userId == null) {
      return null;
    }
    final conversation = currentConversation;
    if (conversation?.peerUserId == userId) {
      return conversation!.peerDisplayName ?? conversation.peerUsername;
    }
    return null;
  }

  Future<void> _waitForConversationKey(String conversationId) async {
    await _ensureConversationKey(conversationId);
    if (_e2ee.conversationKeys.containsKey(conversationId)) {
      return;
    }
    for (var attempt = 0; attempt < 12; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _ensureConversationKey(conversationId);
      if (_e2ee.conversationKeys.containsKey(conversationId)) {
        return;
      }
    }
  }

  MessageCursor? _cursor() {
    if (messages.isEmpty) {
      return null;
    }
    final last = messages.last;
    return MessageCursor(createdAt: last.createdAt, id: last.id);
  }

  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }
}
