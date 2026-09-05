import 'package:flutter/material.dart';

class EfelantComposer extends StatefulWidget {
  const EfelantComposer({
    super.key,
    required this.onSend,
    this.enabled = true,
    this.placeholder = 'Message',
  });

  final ValueChanged<String> onSend;
  final bool enabled;
  final String placeholder;

  @override
  State<EfelantComposer> createState() => _EfelantComposerState();
}

class _EfelantComposerState extends State<EfelantComposer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled) {
      return;
    }
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            enabled: widget.enabled,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(hintText: widget.placeholder),
          ),
        ),
        IconButton(onPressed: widget.enabled ? _submit : null, icon: const Icon(Icons.send)),
      ],
    );
  }
}
