import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_state.dart';

Future<void> showEfelantHostEditor(BuildContext context) async {
  final auth = context.read<AuthState>();
  final controller = TextEditingController(text: auth.hostOverride);
  try {
    final next = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('efelant host'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (value) => Navigator.of(context).pop(value),
            decoration: InputDecoration(
              labelText: 'host',
              hintText: kIsWeb
                  ? 'wss://chat.example.com/ws'
                  : '10.0.2.2',
              helperText:
                  'Empty uses the built-in default. Changing host signs you out.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(''),
              child: const Text('default'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('save'),
            ),
          ],
        );
      },
    );
    if (next == null || !context.mounted) {
      return;
    }
    await auth.setHost(next);
  } finally {
    controller.dispose();
  }
}

class EfelantHostTile extends StatelessWidget {
  const EfelantHostTile({super.key, this.contentPadding});

  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    return ListTile(
      contentPadding: contentPadding,
      title: const Text('efelant host'),
      subtitle: Text(auth.hostLabel),
      trailing: const Icon(Icons.edit_outlined),
      onTap: () => showEfelantHostEditor(context),
    );
  }
}
