import 'package:flutter/material.dart';

class EfelantStatusEvent extends StatelessWidget {
  const EfelantStatusEvent({
    super.key,
    required this.status,
    this.message,
  });

  final String status;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.flag_outlined),
      title: Text(status),
      subtitle: message == null || message!.isEmpty ? null : Text(message!),
    );
  }
}
