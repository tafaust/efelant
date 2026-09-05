import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_state.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  String? _localError;

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_password.text != _repeat.text) {
      setState(() => _localError = 'passwords do not match');
      return;
    }
    setState(() => _localError = null);
    final auth = context.read<AuthState>();
    try {
      await auth.register(
        username: _username.text,
        displayName: _displayName.text,
        password: _password.text,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final error = _localError ?? auth.error;
    return Scaffold(
      appBar: AppBar(title: const Text('register')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: 'username'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _displayName,
                decoration: const InputDecoration(labelText: 'display name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'password'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _repeat,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'repeat password'),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: auth.busy ? null : _submit,
                child: const Text('create account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
