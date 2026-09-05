import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app/theme.dart';
import '../models/models.dart';
import '../state/chat_state.dart';
import '../widgets/emoji_picker.dart';
import '../widgets/message_bubble.dart';
import '../widgets/presence_dot.dart';
import '../widgets/typing_indicator.dart';

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _input = TextEditingController();
  late final ChatState _chat;
  String? _replyTo;

  @override
  void initState() {
    super.initState();
    _chat = context.read<ChatState>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chat.loadConversation(widget.conversationId);
    });
  }

  @override
  void dispose() {
    _chat.leaveConversationView(widget.conversationId);
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text;
    _input.clear();
    final replyTo = _replyTo;
    setState(() => _replyTo = null);
    await _chat.sendText(text, replyTo: replyTo);
  }

  void _insertEmoji(String emoji) {
    final text = _input.text;
    final selection = _input.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final next = text.replaceRange(start, end, emoji);
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    _chat.typingChanged(next);
  }

  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    _send();
    return KeyEventResult.handled;
  }

  Future<void> _attach() async {
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null || picked.files.isEmpty) {
      return;
    }
    final file = picked.files.first;
    if (file.bytes == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    await context.read<ChatState>().sendAttachment(
      filename: file.name,
      mimeType: file.extension == 'png'
          ? 'image/png'
          : file.extension == 'jpg' || file.extension == 'jpeg'
          ? 'image/jpeg'
          : 'application/octet-stream',
      data: file.bytes!,
    );
  }

  Future<void> _edit(ChatMessage message) async {
    final controller = TextEditingController(text: message.content ?? '');
    final next = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('edit message'),
          content: TextField(controller: controller, maxLines: 4),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('save'),
            ),
          ],
        );
      },
    );
    if (next != null && next.trim().isNotEmpty && mounted) {
      await context.read<ChatState>().edit(message, next.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatState>();
    final conversation = chat.currentConversation;
    final title = conversation?.title ?? 'conversation';

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
            if (conversation?.isDirect == true) ...[
              const SizedBox(width: 8),
              PresenceDot(online: conversation!.peerOnline),
            ],
          ],
        ),
      ),
      body: Column(
        children: [
          if (chat.error != null)
            MaterialBanner(
              content: Text(chat.error!),
              actions: const [SizedBox.shrink()],
            ),
          Expanded(
            child: chat.loadingMessages
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 12, bottom: 8),
                    itemCount: chat.messages.length,
                    itemBuilder: (context, index) {
                      final message = chat.messages[index];
                      final mine = message.senderId == chat.userId;
                      return MessageBubble(
                        message: message,
                        mine: mine,
                        showSender: conversation?.isGroup == true,
                        receipt: chat.statusFor(message),
                        onEdit: () => _edit(message),
                        onDelete: () => chat.remove(message),
                        onReply: () => setState(() => _replyTo = message.id),
                        onReact: () async {
                          final emoji = await showEmojiPicker(context);
                          if (emoji != null && mounted) {
                            await chat.toggleReaction(message, emoji);
                          }
                        },
                        onOpenAttachment: () async {
                          if (message.attachmentId == null) {
                            return;
                          }
                          final payload = await chat.downloadAttachment(
                            message.attachmentId!,
                          );
                          if (!context.mounted) {
                            return;
                          }
                          await showDialog<void>(
                            context: context,
                            builder: (context) {
                              return AlertDialog(
                                title: Text(payload.filename),
                                content: Text('${payload.size} bytes'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('close'),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                        onRetry: () => chat.retry(message),
                      );
                    },
                  ),
          ),
          TypingIndicator(
            visible: chat.typingUserId != null,
            label: chat.typingLabel,
          ),
          if (_replyTo != null)
            ListTile(
              dense: true,
              title: const Text('replying'),
              trailing: IconButton(
                onPressed: () => setState(() => _replyTo = null),
                icon: const Icon(Icons.close),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'attach',
                    onPressed: _attach,
                    icon: const Icon(Icons.attach_file),
                  ),
                  IconButton(
                    tooltip: 'emoji',
                    onPressed: () async {
                      final emoji = await showEmojiPicker(context);
                      if (emoji != null && mounted) {
                        _insertEmoji(emoji);
                      }
                    },
                    icon: const Text(
                      '😊',
                      style: TextStyle(
                        fontSize: 22,
                        height: 1,
                        fontFamily: 'EfelantEmoji',
                        fontFamilyFallback: kEfelantEmojiFallback,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Focus(
                      onKeyEvent: _onComposerKey,
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        decoration: const InputDecoration(hintText: 'message'),
                        onChanged: chat.typingChanged,
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'send',
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
