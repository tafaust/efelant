import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/theme.dart';
import '../models/models.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.showSender,
    required this.receipt,
    required this.onEdit,
    required this.onDelete,
    required this.onReply,
    required this.onReact,
    required this.onOpenAttachment,
    required this.onRetry,
  });

  final ChatMessage message;
  final bool mine;
  final bool showSender;
  final ReceiptStatus receipt;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onReply;
  final VoidCallback onReact;
  final VoidCallback onOpenAttachment;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final time = DateFormat.Hm().format(message.createdAt.toLocal());
    final body = message.isDeleted
        ? 'message deleted'
        : (message.content ?? '');

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: GestureDetector(
          onLongPress: () => _menu(context),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: mine
                  ? EfelantColors.bubbleMine
                  : EfelantColors.bubbleTheirs,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(mine ? 16 : 4),
                bottomRight: Radius.circular(mine ? 4 : 16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showSender && !mine)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      message.senderDisplayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: EfelantColors.accentSoft,
                      ),
                    ),
                  ),
                if (message.replyTo != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'reply',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                Text(
                  body,
                  style: TextStyle(
                    fontFamilyFallback: kEfelantEmojiFallback,
                    fontStyle: message.isDeleted
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
                if (message.attachmentId != null && !message.isDeleted)
                  TextButton(
                    onPressed: onOpenAttachment,
                    child: Text(message.attachmentFilename ?? 'attachment'),
                  ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(time, style: Theme.of(context).textTheme.labelSmall),
                    if (message.editedAt != null)
                      Text(
                        '  edited',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    if (mine) ...[
                      const SizedBox(width: 6),
                      Icon(
                        _receiptIcon(receipt),
                        size: 14,
                        color: receipt == ReceiptStatus.viewed
                            ? EfelantColors.accentSoft
                            : null,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _receiptLabel(receipt),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ],
                ),
                if (message.reactions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      children: [
                        for (final group in _grouped(message.reactions).entries)
                          Text(
                            '${group.key} ${group.value}',
                            style: const TextStyle(
                              fontFamilyFallback: kEfelantEmojiFallback,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _receiptIcon(ReceiptStatus status) {
    switch (status) {
      case ReceiptStatus.failed:
        return Icons.error_outline;
      case ReceiptStatus.sending:
        return Icons.schedule;
      case ReceiptStatus.onServer:
        return Icons.done;
      case ReceiptStatus.delivered:
        return Icons.done_all;
      case ReceiptStatus.viewed:
        return Icons.done_all;
    }
  }

  String _receiptLabel(ReceiptStatus status) {
    switch (status) {
      case ReceiptStatus.failed:
        return 'failed';
      case ReceiptStatus.sending:
        return 'sending';
      case ReceiptStatus.onServer:
        return 'on server';
      case ReceiptStatus.delivered:
        return 'delivered';
      case ReceiptStatus.viewed:
        return 'viewed';
    }
  }

  Map<String, int> _grouped(List<Reaction> reactions) {
    final counts = <String, int>{};
    for (final reaction in reactions) {
      counts[reaction.emoji] = (counts[reaction.emoji] ?? 0) + 1;
    }
    return counts;
  }

  Future<void> _menu(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('reply'),
                onTap: () => Navigator.pop(context, 'reply'),
              ),
              ListTile(
                title: const Text('react'),
                onTap: () => Navigator.pop(context, 'react'),
              ),
              if (mine && !message.isDeleted)
                ListTile(
                  title: const Text('edit'),
                  onTap: () => Navigator.pop(context, 'edit'),
                ),
              if (mine && !message.isDeleted)
                ListTile(
                  title: const Text('delete'),
                  onTap: () => Navigator.pop(context, 'delete'),
                ),
              if (message.sendState == SendState.failed)
                ListTile(
                  title: const Text('retry'),
                  onTap: () => Navigator.pop(context, 'retry'),
                ),
            ],
          ),
        );
      },
    );

    switch (choice) {
      case 'reply':
        onReply();
      case 'react':
        onReact();
      case 'edit':
        onEdit();
      case 'delete':
        onDelete();
      case 'retry':
        onRetry();
      default:
        break;
    }
  }
}
