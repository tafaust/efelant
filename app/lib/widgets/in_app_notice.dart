import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/theme.dart';
import '../screens/conversation_screen.dart';
import '../state/chat_state.dart';

class InAppNoticeHost extends StatelessWidget {
  const InAppNoticeHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatState>();
    final notice = chat.notice;
    return Stack(
      children: [
        child,
        if (notice != null)
          Positioned(
            top: 0,
            left: 12,
            right: 12,
            child: SafeArea(
              child: Material(
                color: EfelantColors.navyMid,
                elevation: 6,
                borderRadius: BorderRadius.circular(16),
                child: ListTile(
                  title: Text(notice.title),
                  subtitle: Text(
                    notice.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    onPressed: chat.dismissNotice,
                    icon: const Icon(Icons.close),
                  ),
                  onTap: () {
                    final id = notice.conversationId;
                    chat.dismissNotice();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ConversationScreen(conversationId: id),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }
}
