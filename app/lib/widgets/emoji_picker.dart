import 'package:flutter/material.dart';

const kEfelantEmojis = <String>[
  '😀',
  '😂',
  '😍',
  '🥰',
  '😎',
  '😢',
  '😡',
  '👍',
  '👎',
  '❤️',
  '🔥',
  '🎉',
  '🙏',
  '👏',
  '🤔',
  '😅',
  '🤣',
  '😭',
  '💯',
  '✨',
  '✅',
  '👀',
  '🤝',
  '🐘',
];

Future<String?> showEmojiPicker(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final emoji in kEfelantEmojis)
                InkWell(
                  onTap: () => Navigator.pop(context, emoji),
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Center(
                      child: Text(
                        emoji,
                        style: const TextStyle(
                          fontSize: 22,
                          fontFamily: 'EfelantEmoji',
                          fontFamilyFallback: ['EfelantSans'],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
