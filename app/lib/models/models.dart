import 'dart:convert';
import 'dart:typed_data';

DateTime asDateTime(Object? value) {
  if (value is DateTime) {
    return value;
  }
  return DateTime.parse(value.toString());
}

DateTime? asDateTimeOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  return asDateTime(value);
}

Uint8List? asBytes(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is Uint8List) {
    return value;
  }
  if (value is List<int>) {
    return Uint8List.fromList(value);
  }
  if (value is Map && value['__bytea'] != null) {
    return base64Decode(value['__bytea'].toString());
  }
  return null;
}

class AuthSession {
  const AuthSession({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.sessionId,
    required this.deviceId,
    required this.expiresAt,
    this.sessionToken,
  });

  final String userId;
  final String username;
  final String displayName;
  final String sessionId;
  final String deviceId;
  final DateTime expiresAt;
  final String? sessionToken;

  factory AuthSession.fromRow(Map<String, Object?> row) {
    return AuthSession(
      userId: row['user_id'].toString(),
      username: row['username'].toString(),
      displayName: row['display_name'].toString(),
      sessionId: row['session_id'].toString(),
      deviceId: row['device_id'].toString(),
      expiresAt: asDateTime(row['expires_at']),
      sessionToken: row['session_token']?.toString(),
    );
  }
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.createdAt,
    required this.lastSeenAt,
  });

  final String id;
  final String name;
  final String platform;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  factory DeviceInfo.fromRow(Map<String, Object?> row) {
    return DeviceInfo(
      id: row['id'].toString(),
      name: row['name'].toString(),
      platform: row['platform'].toString(),
      createdAt: asDateTime(row['created_at']),
      lastSeenAt: asDateTime(row['last_seen_at']),
    );
  }
}

class Conversation {
  const Conversation({
    required this.id,
    required this.type,
    required this.title,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.peerOnline,
    required this.unreadCount,
    required this.myRole,
    this.peerUserId,
    this.peerUsername,
    this.peerDisplayName,
    this.lastMessageId,
    this.lastMessageContent,
    this.lastMessageType,
    this.lastMessageAt,
    this.lastMessageSenderId,
    this.lastReadMessageId,
    this.peerLastReadMessageId,
    this.peerLastDeliveredMessageId,
    this.lastMessageEncrypted = false,
  });

  final String id;
  final String type;
  final String title;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? peerUserId;
  final String? peerUsername;
  final String? peerDisplayName;
  final bool peerOnline;
  final String? lastMessageId;
  final String? lastMessageContent;
  final String? lastMessageType;
  final DateTime? lastMessageAt;
  final String? lastMessageSenderId;
  final String? lastReadMessageId;
  final String? peerLastReadMessageId;
  final String? peerLastDeliveredMessageId;
  final int unreadCount;
  final String myRole;
  final bool lastMessageEncrypted;

  bool get isDirect => type == 'direct';
  bool get isGroup => type == 'group';

  Conversation withPeerOnline(bool online) {
    return Conversation(
      id: id,
      type: type,
      title: title,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt,
      peerOnline: online,
      unreadCount: unreadCount,
      myRole: myRole,
      peerUserId: peerUserId,
      peerUsername: peerUsername,
      peerDisplayName: peerDisplayName,
      lastMessageId: lastMessageId,
      lastMessageContent: lastMessageContent,
      lastMessageType: lastMessageType,
      lastMessageAt: lastMessageAt,
      lastMessageSenderId: lastMessageSenderId,
      lastReadMessageId: lastReadMessageId,
      peerLastReadMessageId: peerLastReadMessageId,
      peerLastDeliveredMessageId: peerLastDeliveredMessageId,
      lastMessageEncrypted: lastMessageEncrypted,
    );
  }

  factory Conversation.fromRow(Map<String, Object?> row) {
    return Conversation(
      id: row['id'].toString(),
      type: row['type'].toString(),
      title: (row['title'] ?? 'conversation').toString(),
      createdBy: row['created_by'].toString(),
      createdAt: asDateTime(row['created_at']),
      updatedAt: asDateTime(row['updated_at']),
      peerUserId: row['peer_user_id']?.toString(),
      peerUsername: row['peer_username']?.toString(),
      peerDisplayName: row['peer_display_name']?.toString(),
      peerOnline: row['peer_online'] == true,
      lastMessageId: row['last_message_id']?.toString(),
      lastMessageContent: row['last_message_content']?.toString(),
      lastMessageType: row['last_message_type']?.toString(),
      lastMessageAt: asDateTimeOrNull(row['last_message_at']),
      lastMessageSenderId: row['last_message_sender_id']?.toString(),
      lastReadMessageId: row['last_read_message_id']?.toString(),
      peerLastReadMessageId: row['peer_last_read_message_id']?.toString(),
      peerLastDeliveredMessageId: row['peer_last_delivered_message_id']
          ?.toString(),
      unreadCount: (row['unread_count'] as num?)?.toInt() ?? 0,
      myRole: (row['my_role'] ?? 'member').toString(),
      lastMessageEncrypted:
          row['last_message_content'] == null && row['last_message_id'] != null,
    );
  }
}

class Reaction {
  const Reaction({required this.emoji, required this.userId});

  final String emoji;
  final String userId;

  factory Reaction.fromJson(Map<String, dynamic> json) {
    return Reaction(
      emoji: json['emoji'].toString(),
      userId: json['user_id'].toString(),
    );
  }
}

enum SendState { sent, sending, failed }

enum ReceiptStatus { sending, onServer, delivered, viewed, failed }

bool messageCoveredByCursor({
  required List<ChatMessage> thread,
  required ChatMessage message,
  required String? cursorId,
}) {
  if (cursorId == null) {
    return false;
  }
  ChatMessage? cursor;
  for (final item in thread) {
    if (item.id == cursorId) {
      cursor = item;
      break;
    }
  }
  if (cursor == null) {
    return message.id == cursorId;
  }
  final byTime = message.createdAt.compareTo(cursor.createdAt);
  if (byTime != 0) {
    return byTime <= 0;
  }
  return message.id.compareTo(cursor.id) <= 0;
}

ReceiptStatus receiptStatus({
  required SendState sendState,
  required ChatMessage message,
  required List<ChatMessage> thread,
  required String? deliveredThroughId,
  required String? viewedThroughId,
}) {
  switch (sendState) {
    case SendState.failed:
      return ReceiptStatus.failed;
    case SendState.sending:
      return ReceiptStatus.sending;
    case SendState.sent:
      if (messageCoveredByCursor(
        thread: thread,
        message: message,
        cursorId: viewedThroughId,
      )) {
        return ReceiptStatus.viewed;
      }
      if (messageCoveredByCursor(
        thread: thread,
        message: message,
        cursorId: deliveredThroughId,
      )) {
        return ReceiptStatus.delivered;
      }
      return ReceiptStatus.onServer;
  }
}

class IncomingNotice {
  const IncomingNotice({
    required this.conversationId,
    required this.title,
    required this.preview,
  });

  final String conversationId;
  final String title;
  final String preview;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderUsername,
    required this.senderDisplayName,
    required this.clientId,
    required this.type,
    required this.createdAt,
    required this.reactions,
    this.content,
    this.replyTo,
    this.editedAt,
    this.deletedAt,
    this.attachmentId,
    this.attachmentFilename,
    this.attachmentMimeType,
    this.attachmentSize,
    this.encryptedContent,
    this.sendState = SendState.sent,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String senderUsername;
  final String senderDisplayName;
  final String clientId;
  final String type;
  final String? content;
  final String? replyTo;
  final DateTime createdAt;
  final DateTime? editedAt;
  final DateTime? deletedAt;
  final List<Reaction> reactions;
  final String? attachmentId;
  final String? attachmentFilename;
  final String? attachmentMimeType;
  final int? attachmentSize;
  final Uint8List? encryptedContent;
  final SendState sendState;

  bool get isDeleted => deletedAt != null;
  bool get isMine => false;

  ChatMessage copyWith({
    SendState? sendState,
    String? id,
    String? content,
    List<Reaction>? reactions,
    Uint8List? encryptedContent,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId,
      senderId: senderId,
      senderUsername: senderUsername,
      senderDisplayName: senderDisplayName,
      clientId: clientId,
      type: type,
      content: content ?? this.content,
      replyTo: replyTo,
      createdAt: createdAt,
      editedAt: editedAt,
      deletedAt: deletedAt,
      reactions: reactions ?? this.reactions,
      attachmentId: attachmentId,
      attachmentFilename: attachmentFilename,
      attachmentMimeType: attachmentMimeType,
      attachmentSize: attachmentSize,
      encryptedContent: encryptedContent ?? this.encryptedContent,
      sendState: sendState ?? this.sendState,
    );
  }

  factory ChatMessage.fromRow(Map<String, Object?> row) {
    final rawReactions = row['reactions'];
    final reactions = <Reaction>[];
    if (rawReactions is List) {
      for (final item in rawReactions) {
        if (item is Map) {
          reactions.add(Reaction.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    return ChatMessage(
      id: row['id'].toString(),
      conversationId: row['conversation_id'].toString(),
      senderId: row['sender_id'].toString(),
      senderUsername: (row['sender_username'] ?? '').toString(),
      senderDisplayName: (row['sender_display_name'] ?? '').toString(),
      clientId: row['client_id'].toString(),
      type: row['type'].toString(),
      content: row['content']?.toString(),
      replyTo: row['reply_to']?.toString(),
      createdAt: asDateTime(row['created_at']),
      editedAt: asDateTimeOrNull(row['edited_at']),
      deletedAt: asDateTimeOrNull(row['deleted_at']),
      reactions: reactions,
      attachmentId: row['attachment_id']?.toString(),
      attachmentFilename: row['attachment_filename']?.toString(),
      attachmentMimeType: row['attachment_mime_type']?.toString(),
      attachmentSize: (row['attachment_size'] as num?)?.toInt(),
      encryptedContent: asBytes(row['encrypted_content']),
    );
  }
}

class UserHit {
  const UserHit({
    required this.id,
    required this.username,
    required this.displayName,
  });

  final String id;
  final String username;
  final String displayName;

  factory UserHit.fromRow(Map<String, Object?> row) {
    return UserHit(
      id: row['id'].toString(),
      username: row['username'].toString(),
      displayName: row['display_name'].toString(),
    );
  }
}

class AttachmentPayload {
  const AttachmentPayload({
    required this.id,
    required this.messageId,
    required this.filename,
    required this.mimeType,
    required this.size,
    required this.data,
  });

  final String id;
  final String messageId;
  final String filename;
  final String mimeType;
  final int size;
  final List<int> data;
}

class RealtimeEvent {
  const RealtimeEvent({required this.type, required this.payload});

  final String type;
  final Map<String, dynamic> payload;

  String? get conversationId => payload['conversation_id']?.toString();
  String? get messageId => payload['message_id']?.toString();
  String? get userId => payload['user_id']?.toString();
  bool? get online {
    final value = payload['online'];
    if (value is bool) {
      return value;
    }
    return null;
  }
}

class MessageCursor {
  const MessageCursor({required this.createdAt, required this.id});

  final DateTime createdAt;
  final String id;
}

class EfelantException implements Exception {
  EfelantException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}
