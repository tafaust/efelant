import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../app/theme.dart';
import '../state/chat_state.dart';
import '../widgets/presence_dot.dart';
import 'conversation_screen.dart';
import 'new_conversation_screen.dart';
import 'settings_screen.dart';

class ConversationListScreen extends StatelessWidget {
  const ConversationListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('efelant'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const NewConversationScreen()),
          );
        },
        child: const Icon(Icons.edit_outlined),
      ),
      body: RefreshIndicator(
        onRefresh: chat.refreshConversations,
        child: chat.conversations.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(child: Text('no conversations yet')),
                ],
              )
            : ListView.separated(
                itemCount: chat.conversations.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final conversation = chat.conversations[index];
                  final time = conversation.lastMessageAt == null
                      ? ''
                      : DateFormat.Hm().format(
                          conversation.lastMessageAt!.toLocal(),
                        );
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: EfelantColors.navyLight,
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          Center(
                            child: Text(
                              conversation.title.isEmpty
                                  ? '?'
                                  : conversation.title[0].toUpperCase(),
                            ),
                          ),
                          if (conversation.isDirect)
                            PresenceDot(online: conversation.peerOnline),
                        ],
                      ),
                    ),
                    title: Text(conversation.title),
                    subtitle: Text(
                      conversation.lastMessageContent ??
                          (conversation.lastMessageEncrypted
                              ? 'encrypted message'
                              : conversation.lastMessageType ??
                                    'no messages yet'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          time,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        if (conversation.unreadCount > 0)
                          Container(
                            margin: const EdgeInsets.only(top: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: EfelantColors.accent,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text('${conversation.unreadCount}'),
                          ),
                      ],
                    ),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ConversationScreen(
                            conversationId: conversation.id,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}
