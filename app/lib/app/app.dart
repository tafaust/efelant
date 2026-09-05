import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/auth_repository.dart';
import '../database/chat_repository.dart';
import '../database/e2ee_service.dart';
import '../database/postgres_client.dart';
import '../database/realtime_service.dart';
import '../screens/conversation_list_screen.dart';
import '../screens/login_screen.dart';
import '../widgets/in_app_notice.dart';
import '../state/auth_state.dart';
import '../state/chat_state.dart';
import 'theme.dart';

class EfelantApp extends StatefulWidget {
  const EfelantApp({
    super.key,
    required this.client,
    required this.auth,
    required this.chat,
    required this.e2ee,
    required this.realtime,
  });

  final PostgresClient client;
  final AuthRepository auth;
  final ChatRepository chat;
  final E2eeService e2ee;
  final RealtimeService realtime;

  @override
  State<EfelantApp> createState() => _EfelantAppState();
}

class _EfelantAppState extends State<EfelantApp> with WidgetsBindingObserver {
  late final AuthState _authState;
  late final ChatState _chatState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authState = AuthState(
      client: widget.client,
      auth: widget.auth,
      e2ee: widget.e2ee,
    );
    _chatState = ChatState(
      chat: widget.chat,
      e2ee: widget.e2ee,
      realtime: widget.realtime,
      currentUserId: () => _authState.session?.userId ?? '',
    );
    widget.client.onReady = () async {
      if (_authState.session != null) {
        await _authState.resumeAfterReconnect();
        await _chatState.syncAfterReconnect();
      }
    };
    _authState.addListener(_onAuth);
    _authState.bootstrap();
  }

  bool _chatStarted = false;

  void _onAuth() {
    if (_authState.session != null && _authState.ready) {
      if (!_chatStarted) {
        _chatStarted = true;
        _chatState.start();
      }
    } else if (_authState.session == null && _authState.ready) {
      _chatStarted = false;
      _chatState.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        widget.client.reconnectNow();
        if (_chatStarted) {
          unawaited(_chatState.goOnline());
        }
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (_chatStarted) {
          unawaited(_chatState.goOffline());
        }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authState.removeListener(_onAuth);
    _chatState.dispose();
    _authState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _authState),
        ChangeNotifierProvider.value(value: _chatState),
      ],
      child: MaterialApp(
        title: 'efelant',
        debugShowCheckedModeBanner: false,
        theme: buildEfelantTheme(),
        home: Consumer<AuthState>(
          builder: (context, auth, _) {
            if (!auth.ready) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (auth.session == null) {
              return const LoginScreen();
            }
            return const InAppNoticeHost(child: ConversationListScreen());
          },
        ),
      ),
    );
  }
}
