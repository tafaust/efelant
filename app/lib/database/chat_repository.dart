import 'dart:typed_data';

import '../models/models.dart';
import 'e2ee_service.dart';
import 'postgres_client.dart';

class ChatRepository {
  ChatRepository(this._client);

  final PostgresClient _client;

  Future<List<Conversation>> getConversations() async {
    final result = await _client.query(
      'SELECT * FROM chat.get_conversations()',
    );
    return result.map(Conversation.fromRow).toList();
  }

  Future<String> createDirect(String otherUserId) async {
    final result = await _client.query(
      'SELECT conversation_id FROM chat.create_direct_conversation(@id::uuid)',
      parameters: {'id': otherUserId},
    );
    return result.first['conversation_id'].toString();
  }

  Future<String> createGroup(String title, List<String> memberIds) async {
    final result = await _client.query(
      'SELECT chat.create_group(@title::text, @members::uuid[]) AS id',
      parameters: {'title': title, 'members': memberIds},
    );
    return result.first['id'].toString();
  }

  Future<ChatMessage> sendMessage({
    required String conversationId,
    required String clientId,
    required String type,
    String? content,
    Uint8List? encryptedContent,
    String? replyTo,
  }) async {
    final result = await _client.query(
      '''
      SELECT
        id, conversation_id, sender_id, client_id, type, content, reply_to,
        created_at, edited_at, deleted_at
      FROM chat.send_message(
        @conversation_id::uuid,
        @client_id::uuid,
        @type::text,
        @content::text,
        @encrypted_content::bytea,
        @reply_to::uuid
      )
      ''',
      parameters: {
        'conversation_id': conversationId,
        'client_id': clientId,
        'type': type,
        'content': content,
        'encrypted_content': encryptedContent,
        'reply_to': replyTo,
      },
    );
    final row = result.first;
    return ChatMessage(
      id: row['id'].toString(),
      conversationId: row['conversation_id'].toString(),
      senderId: row['sender_id'].toString(),
      senderUsername: '',
      senderDisplayName: '',
      clientId: row['client_id'].toString(),
      type: row['type'].toString(),
      content: row['content']?.toString(),
      replyTo: row['reply_to']?.toString(),
      createdAt: asDateTime(row['created_at']),
      editedAt: asDateTimeOrNull(row['edited_at']),
      deletedAt: asDateTimeOrNull(row['deleted_at']),
      reactions: const [],
      encryptedContent: encryptedContent,
    );
  }

  Future<void> editMessage(String messageId, String content) async {
    await _client.query(
      'SELECT chat.edit_message(@id::uuid, @content::text)',
      parameters: {'id': messageId, 'content': content},
    );
  }

  Future<void> deleteMessage(String messageId) async {
    await _client.query(
      'SELECT chat.delete_message(@id::uuid)',
      parameters: {'id': messageId},
    );
  }

  Future<List<ChatMessage>> getMessages(String conversationId) async {
    final result = await _client.query(
      '''
      SELECT * FROM chat.get_messages(
        @id::uuid, 80, NULL::timestamptz, NULL::uuid
      )
      ''',
      parameters: {'id': conversationId},
    );
    return result.map(ChatMessage.fromRow).toList().reversed.toList();
  }

  Future<List<ChatMessage>> getMessagesAfter(
    String conversationId,
    MessageCursor cursor,
  ) async {
    final result = await _client.query(
      '''
      SELECT * FROM chat.get_messages_after(
        @id::uuid,
        @created_at::timestamptz,
        @after_id::uuid
      )
      ''',
      parameters: {
        'id': conversationId,
        'created_at': cursor.createdAt,
        'after_id': cursor.id,
      },
    );
    return result.map(ChatMessage.fromRow).toList();
  }

  Future<ChatMessage> getMessage(String messageId) async {
    final result = await _client.query(
      'SELECT * FROM chat.get_message(@id::uuid)',
      parameters: {'id': messageId},
    );
    return ChatMessage.fromRow(result.first);
  }

  Future<void> markRead(String conversationId, String messageId) async {
    await _client.query(
      'SELECT chat.mark_read(@conversation_id::uuid, @message_id::uuid)',
      parameters: {'conversation_id': conversationId, 'message_id': messageId},
    );
  }

  Future<void> markDelivered(String conversationId, String messageId) async {
    await _client.query(
      'SELECT chat.mark_delivered(@conversation_id::uuid, @message_id::uuid)',
      parameters: {'conversation_id': conversationId, 'message_id': messageId},
    );
  }

  Future<({String? deliveredId, String? readId})> getPeerReceipts(
    String conversationId,
  ) async {
    final result = await _client.query(
      'SELECT * FROM chat.get_peer_receipts(@id::uuid)',
      parameters: {'id': conversationId},
    );
    if (result.isEmpty) {
      return (deliveredId: null, readId: null);
    }
    final row = result.first;
    return (
      deliveredId: row['last_delivered_message_id']?.toString(),
      readId: row['last_read_message_id']?.toString(),
    );
  }

  Future<void> addReaction(String messageId, String emoji) async {
    await _client.query(
      'SELECT chat.add_reaction(@id::uuid, @emoji::text)',
      parameters: {'id': messageId, 'emoji': emoji},
    );
  }

  Future<void> removeReaction(String messageId, String emoji) async {
    await _client.query(
      'SELECT chat.remove_reaction(@id::uuid, @emoji::text)',
      parameters: {'id': messageId, 'emoji': emoji},
    );
  }

  Future<void> uploadAttachment({
    required String messageId,
    required String filename,
    required String mimeType,
    required Uint8List data,
  }) async {
    await _client.query(
      '''
      SELECT chat.upload_attachment(
        @message_id::uuid,
        @filename::text,
        @mime_type::text,
        @data::bytea
      )
      ''',
      parameters: {
        'message_id': messageId,
        'filename': filename,
        'mime_type': mimeType,
        'data': data,
      },
      timeout: const Duration(seconds: 60),
    );
  }

  Future<AttachmentPayload> getAttachment(String attachmentId) async {
    final result = await _client.query(
      'SELECT * FROM chat.get_attachment(@id::uuid)',
      parameters: {'id': attachmentId},
      timeout: const Duration(seconds: 60),
    );
    final row = result.first;
    final data = row['data'];
    return AttachmentPayload(
      id: row['id'].toString(),
      messageId: row['message_id'].toString(),
      filename: row['filename'].toString(),
      mimeType: row['mime_type'].toString(),
      size: (row['size'] as num).toInt(),
      data: data is Uint8List ? data : Uint8List.fromList(data as List<int>),
    );
  }

  Future<List<UserHit>> searchUsers(String query) async {
    final result = await _client.query(
      'SELECT * FROM chat.search_users(@query::text)',
      parameters: {'query': query},
    );
    return result.map(UserHit.fromRow).toList();
  }

  Future<void> heartbeat() async {
    await _client.query('SELECT chat.heartbeat()');
  }

  Future<void> setOffline() async {
    await _client.query('SELECT chat.set_offline()');
  }

  Future<void> setTyping(String conversationId, bool isTyping) async {
    await _client.query(
      'SELECT chat.set_typing(@id::uuid, @typing::boolean)',
      parameters: {'id': conversationId, 'typing': isTyping},
    );
  }

  Future<void> addMember(String conversationId, String userId) async {
    await _client.query(
      'SELECT chat.add_member(@conversation_id::uuid, @user_id::uuid)',
      parameters: {'conversation_id': conversationId, 'user_id': userId},
    );
  }

  Future<void> removeMember(String conversationId, String userId) async {
    await _client.query(
      'SELECT chat.remove_member(@conversation_id::uuid, @user_id::uuid)',
      parameters: {'conversation_id': conversationId, 'user_id': userId},
    );
  }

  Future<List<DevicePublicKey>> memberDeviceKeys(String conversationId) async {
    final result = await _client.query(
      'SELECT * FROM chat.member_device_keys(@id::uuid)',
      parameters: {'id': conversationId},
    );
    return [
      for (final row in result)
        DevicePublicKey(
          deviceId: row['device_id'].toString(),
          publicKey: asBytes(row['identity_public_key'])!,
        ),
    ];
  }

  Future<void> putConversationKeyWrap({
    required String conversationId,
    required String deviceId,
    required Uint8List wrappedKey,
  }) async {
    await _client.query(
      '''
      SELECT chat.put_conversation_key_wrap(
        @conversation_id::uuid,
        @device_id::uuid,
        @wrapped::bytea
      )
      ''',
      parameters: {
        'conversation_id': conversationId,
        'device_id': deviceId,
        'wrapped': wrappedKey,
      },
    );
  }

  Future<bool> hasConversationKeyWraps(String conversationId) async {
    final result = await _client.query(
      'SELECT chat.has_conversation_key_wraps(@id::uuid) AS present',
      parameters: {'id': conversationId},
    );
    return result.first['present'] == true;
  }

  Future<Uint8List?> getConversationKeyWrap(String conversationId) async {
    final result = await _client.query(
      'SELECT wrapped_key FROM chat.get_conversation_key_wrap(@id::uuid)',
      parameters: {'id': conversationId},
    );
    if (result.isEmpty) {
      return null;
    }
    return asBytes(result.first['wrapped_key']);
  }

  Future<List<ConversationKeyWrap>> getConversationKeyWraps(
    String conversationId,
  ) async {
    final result = await _client.query(
      'SELECT * FROM chat.get_conversation_key_wraps(@id::uuid)',
      parameters: {'id': conversationId},
    );
    return [
      for (final row in result)
        ConversationKeyWrap(
          deviceId: row['device_id'].toString(),
          wrappedKey: asBytes(row['wrapped_key'])!,
        ),
    ];
  }

  Future<Map<String, Uint8List>> getCiphertexts(String conversationId) async {
    final result = await _client.query(
      'SELECT * FROM chat.get_ciphertexts(@id::uuid)',
      parameters: {'id': conversationId},
    );
    return {
      for (final row in result)
        row['message_id'].toString(): asBytes(row['encrypted_content'])!,
    };
  }

  Future<void> editEncrypted(String messageId, Uint8List ciphertext) async {
    await _client.query(
      'SELECT chat.edit_encrypted_message(@id::uuid, @data::bytea)',
      parameters: {'id': messageId, 'data': ciphertext},
    );
  }

  Future<void> leaveConversation(String conversationId) async {
    await _client.query(
      'SELECT chat.leave_conversation(@id::uuid)',
      parameters: {'id': conversationId},
    );
  }
}
