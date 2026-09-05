import 'package:efelant/app/theme.dart';
import 'package:efelant/config.dart';
import 'package:efelant/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default config talks to local postgres as efelant_app', () {
    const config = EfelantConfig.defaults;
    expect(config.host, 'localhost');
    expect(config.port, 5432);
    expect(config.username, 'efelant_app');
    expect(config.database, 'efelant');
  });

  test('published web port uses same-origin websocket', () {
    expect(
      websocketUrlFor(
        override: '',
        isWeb: true,
        page: Uri.parse('http://localhost:8080/'),
      ),
      'ws://localhost:8080/ws',
    );
    expect(
      websocketUrlFor(
        override: '',
        isWeb: true,
        page: Uri.parse('https://chat.example.com/'),
      ),
      'wss://chat.example.com/ws',
    );
  });

  test('flutter debug web falls back to local gateway', () {
    expect(
      websocketUrlFor(
        override: '',
        isWeb: true,
        page: Uri.parse('http://localhost:52153/'),
      ),
      'ws://localhost:5433',
    );
  });

  test('explicit websocket override wins', () {
    expect(
      websocketUrlFor(
        override: 'wss://edge.example.com/sql',
        isWeb: true,
        page: Uri.parse('https://chat.example.com/'),
      ),
      'wss://edge.example.com/sql',
    );
  });

  test('receipts distinguish server, delivered, and viewed', () {
    ChatMessage msg(String id, DateTime at) {
      return ChatMessage(
        id: id,
        conversationId: 'c',
        senderId: 'me',
        senderUsername: 'me',
        senderDisplayName: 'me',
        clientId: id,
        type: 'text',
        createdAt: at,
        reactions: const [],
      );
    }

    final first = msg('a', DateTime.utc(2026, 1, 1, 10));
    final second = msg('b', DateTime.utc(2026, 1, 1, 11));
    final thread = [first, second];

    expect(
      receiptStatus(
        sendState: SendState.sending,
        message: first,
        thread: thread,
        deliveredThroughId: null,
        viewedThroughId: null,
      ),
      ReceiptStatus.sending,
    );
    expect(
      receiptStatus(
        sendState: SendState.sent,
        message: first,
        thread: thread,
        deliveredThroughId: null,
        viewedThroughId: null,
      ),
      ReceiptStatus.onServer,
    );
    expect(
      receiptStatus(
        sendState: SendState.sent,
        message: first,
        thread: thread,
        deliveredThroughId: 'a',
        viewedThroughId: null,
      ),
      ReceiptStatus.delivered,
    );
    expect(
      receiptStatus(
        sendState: SendState.sent,
        message: first,
        thread: thread,
        deliveredThroughId: 'b',
        viewedThroughId: 'b',
      ),
      ReceiptStatus.viewed,
    );
  });

  test('theme uses navy and accent', () {
    final theme = buildEfelantTheme();
    expect(theme.scaffoldBackgroundColor, EfelantColors.navy);
    expect(theme.colorScheme.primary, EfelantColors.accent);
    expect(theme.textTheme.bodyMedium?.fontFamily, 'EfelantSans');
  });
}
