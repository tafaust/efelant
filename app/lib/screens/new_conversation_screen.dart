import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/chat_state.dart';
import 'conversation_screen.dart';

class NewConversationScreen extends StatefulWidget {
  const NewConversationScreen({super.key});

  @override
  State<NewConversationScreen> createState() => _NewConversationScreenState();
}

class _NewConversationScreenState extends State<NewConversationScreen> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatState>();
    return Scaffold(
      appBar: AppBar(title: const Text('new conversation')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'search users'),
              onChanged: chat.searchUsers,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: chat.userHits.length,
              itemBuilder: (context, index) {
                final user = chat.userHits[index];
                return ListTile(
                  title: Text(user.displayName),
                  subtitle: Text('@${user.username}'),
                  onTap: () async {
                    final id = await chat.startDirect(user.id);
                    if (!context.mounted) {
                      return;
                    }
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => ConversationScreen(conversationId: id),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
