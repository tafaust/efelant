import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_state.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final session = auth.session;
    final device = auth.device;
    final config = auth.config;

    return Scaffold(
      appBar: AppBar(title: const Text('settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: const Text('user'),
            subtitle: Text(
              session == null
                  ? 'signed out'
                  : '${session.displayName} @${session.username}',
            ),
          ),
          ListTile(
            title: const Text('user id'),
            subtitle: Text(session?.userId ?? '-'),
          ),
          ListTile(
            title: const Text('device'),
            subtitle: Text(
              device == null
                  ? (auth.deviceId ?? '-')
                  : '${device.name} · ${device.platform}\n${device.id}',
            ),
          ),
          const Divider(),
          if (kIsWeb)
            ListTile(
              title: const Text('connection'),
              subtitle: Text('same-origin WebSocket\n${config.wsUrl}'),
            )
          else ...[
            ListTile(
              title: const Text('database host'),
              subtitle: Text('${config.host}:${config.port}'),
            ),
            ListTile(
              title: const Text('database'),
              subtitle: Text(config.database),
            ),
            ListTile(
              title: const Text('role'),
              subtitle: Text(config.username),
            ),
            ListTile(
              title: const Text('sslmode'),
              subtitle: Text(config.sslMode),
            ),
          ],
          ListTile(
            title: const Text('device public key'),
            subtitle: Text(auth.publicKeyFingerprint ?? 'not published yet'),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'Messages are encrypted on this device before they reach PostgreSQL. '
              'Private keys never leave the client. Desktop and mobile use the '
              'PostgreSQL wire protocol; web uses a session-preserving WebSocket '
              'adapter with no application logic. Production must verify TLS.',
            ),
          ),
          const Divider(),
          ListTile(
            title: const Text('license'),
            subtitle: const Text('GNU Affero General Public License v3.0 or later'),
            onTap: () {
              showLicensePage(
                context: context,
                applicationName: 'efelant',
                applicationLegalese:
                    'Copyright (C) 2026 tafaust\n'
                    'Licensed under AGPL-3.0-or-later.\n'
                    'https://choosealicense.com/licenses/agpl-3.0/',
              );
            },
          ),
          FilledButton(
            onPressed: () async {
              await auth.logout();
              if (context.mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
            child: const Text('logout'),
          ),
        ],
      ),
    );
  }
}
