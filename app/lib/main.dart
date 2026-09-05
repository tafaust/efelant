import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:uuid/uuid.dart';

import 'app/app.dart';
import 'app/theme.dart';
import 'config.dart';
import 'database/auth_repository.dart';
import 'database/chat_repository.dart';
import 'database/e2ee_service.dart';
import 'database/postgres_client.dart';
import 'database/realtime_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadEfelantFonts();
  if (kIsWeb) {
    SemanticsBinding.instance.ensureSemantics();
  }

  final client = PostgresClient(
    config: EfelantConfig.resolve(),
    deviceId: const Uuid().v7(),
  );
  final auth = AuthRepository(client);
  final chat = ChatRepository(client);
  final e2ee = E2eeService();
  final realtime = RealtimeService(client);

  runApp(
    EfelantApp(
      client: client,
      auth: auth,
      chat: chat,
      e2ee: e2ee,
      realtime: realtime,
    ),
  );
}
