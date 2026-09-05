SET ROLE efelant_owner;
SET search_path = pg_catalog, public, auth, chat, realtime, internal;

CREATE OR REPLACE FUNCTION internal.visible_user(p_viewer uuid, p_target uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT p_viewer IS NOT NULL
     AND p_target IS NOT NULL
     AND (
       p_viewer = p_target
       OR EXISTS (
         SELECT 1
           FROM chat.conversation_members me
           JOIN chat.conversation_members other
             ON other.conversation_id = me.conversation_id
            AND other.left_at IS NULL
          WHERE me.user_id = p_viewer
            AND me.left_at IS NULL
            AND other.user_id = p_target
       )
     );
$$;

CREATE OR REPLACE FUNCTION internal.visible_conversation(p_viewer uuid, p_conversation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT chat.is_active_member(p_conversation_id, p_viewer);
$$;

ALTER TABLE auth.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth.users FORCE ROW LEVEL SECURITY;
ALTER TABLE auth.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth.devices FORCE ROW LEVEL SECURITY;
ALTER TABLE auth.device_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth.device_keys FORCE ROW LEVEL SECURITY;
ALTER TABLE auth.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE auth.sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE chat.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.conversations FORCE ROW LEVEL SECURITY;
ALTER TABLE chat.conversation_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.conversation_members FORCE ROW LEVEL SECURITY;
ALTER TABLE chat.direct_pairs ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.direct_pairs FORCE ROW LEVEL SECURITY;
ALTER TABLE chat.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.messages FORCE ROW LEVEL SECURITY;
ALTER TABLE chat.attachments ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.attachments FORCE ROW LEVEL SECURITY;
ALTER TABLE chat.conversation_reads ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.conversation_reads FORCE ROW LEVEL SECURITY;
ALTER TABLE chat.reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.reactions FORCE ROW LEVEL SECURITY;
ALTER TABLE internal.presence ENABLE ROW LEVEL SECURITY;
ALTER TABLE internal.presence FORCE ROW LEVEL SECURITY;
ALTER TABLE internal.auth_failures ENABLE ROW LEVEL SECURITY;
ALTER TABLE internal.auth_failures FORCE ROW LEVEL SECURITY;
ALTER TABLE internal.app_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE internal.app_settings FORCE ROW LEVEL SECURITY;

CREATE POLICY users_select ON auth.users
  FOR SELECT
  USING (internal.visible_user(auth.current_user_id(), id));

CREATE POLICY devices_own ON auth.devices
  USING (user_id = auth.current_user_id());

CREATE POLICY device_keys_own ON auth.device_keys
  USING (
    EXISTS (
      SELECT 1 FROM auth.devices d
       WHERE d.id = device_id AND d.user_id = auth.current_user_id()
    )
  );

CREATE POLICY sessions_own ON auth.sessions
  USING (user_id = auth.current_user_id());

CREATE POLICY conversations_member ON chat.conversations
  USING (internal.visible_conversation(auth.current_user_id(), id));

CREATE POLICY conversation_members_visible ON chat.conversation_members
  USING (internal.visible_conversation(auth.current_user_id(), conversation_id));

CREATE POLICY direct_pairs_member ON chat.direct_pairs
  USING (user_lo = auth.current_user_id() OR user_hi = auth.current_user_id());

CREATE POLICY messages_member ON chat.messages
  USING (internal.visible_conversation(auth.current_user_id(), conversation_id));

CREATE POLICY attachments_member ON chat.attachments
  USING (
    EXISTS (
      SELECT 1 FROM chat.messages m
       WHERE m.id = message_id
         AND internal.visible_conversation(auth.current_user_id(), m.conversation_id)
    )
  );

CREATE POLICY conversation_reads_member ON chat.conversation_reads
  USING (internal.visible_conversation(auth.current_user_id(), conversation_id));

CREATE POLICY reactions_member ON chat.reactions
  USING (
    EXISTS (
      SELECT 1 FROM chat.messages m
       WHERE m.id = message_id
         AND internal.visible_conversation(auth.current_user_id(), m.conversation_id)
    )
  );

CREATE POLICY presence_visible ON internal.presence
  USING (internal.visible_user(auth.current_user_id(), user_id));

RESET ROLE;

REVOKE ALL ON ALL TABLES IN SCHEMA auth FROM PUBLIC, efelant_app;
REVOKE ALL ON ALL TABLES IN SCHEMA chat FROM PUBLIC, efelant_app;
REVOKE ALL ON ALL TABLES IN SCHEMA realtime FROM PUBLIC, efelant_app;
REVOKE ALL ON ALL TABLES IN SCHEMA internal FROM PUBLIC, efelant_app;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA auth FROM PUBLIC, efelant_app;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA chat FROM PUBLIC, efelant_app;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA realtime FROM PUBLIC, efelant_app;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA internal FROM PUBLIC, efelant_app;

REVOKE ALL ON ALL SEQUENCES IN SCHEMA auth FROM PUBLIC, efelant_app;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA chat FROM PUBLIC, efelant_app;

GRANT USAGE ON TYPE chat.conversation_type TO efelant_app;
GRANT USAGE ON TYPE chat.member_role TO efelant_app;
GRANT USAGE ON TYPE chat.message_type TO efelant_app;
GRANT USAGE ON TYPE chat.messages TO efelant_app;

GRANT EXECUTE ON FUNCTION auth.register(text, text, text, uuid, text, text) TO efelant_app;
GRANT EXECUTE ON FUNCTION auth.login(text, text, uuid, text, text) TO efelant_app;
GRANT EXECUTE ON FUNCTION auth.logout() TO efelant_app;
GRANT EXECUTE ON FUNCTION auth.resume_session(text) TO efelant_app;
GRANT EXECUTE ON FUNCTION auth.current_user_id() TO efelant_app;
GRANT EXECUTE ON FUNCTION auth.current_session_id() TO efelant_app;
GRANT EXECUTE ON FUNCTION auth.current_device_id() TO efelant_app;

GRANT EXECUTE ON FUNCTION chat.create_direct_conversation(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.create_group(text, uuid[]) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.add_member(uuid, uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.remove_member(uuid, uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.leave_conversation(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.send_message(uuid, uuid, text, text, bytea, uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.edit_message(uuid, text) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.delete_message(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.get_conversations() TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.get_messages(uuid, integer, timestamptz, uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.get_messages_after(uuid, timestamptz, uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.get_message(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.mark_read(uuid, uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.add_reaction(uuid, text) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.remove_reaction(uuid, text) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.upload_attachment(uuid, text, text, bytea) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.get_attachment(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.search_users(text) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.heartbeat() TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.set_offline() TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.set_typing(uuid, boolean) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.is_user_online(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.current_device() TO efelant_app;
