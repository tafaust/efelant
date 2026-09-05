SET ROLE efelant_owner;
SET search_path = pg_catalog, public;

CREATE INDEX messages_conversation_created_id_idx
  ON chat.messages (conversation_id, created_at DESC, id DESC);

CREATE INDEX conversation_members_user_conversation_idx
  ON chat.conversation_members (user_id, conversation_id)
  WHERE left_at IS NULL;

CREATE INDEX sessions_token_hash_idx
  ON auth.sessions (token_hash);

CREATE INDEX sessions_user_id_idx
  ON auth.sessions (user_id)
  WHERE revoked_at IS NULL;

CREATE INDEX devices_user_id_idx
  ON auth.devices (user_id);

CREATE INDEX conversation_reads_user_conversation_idx
  ON chat.conversation_reads (user_id, conversation_id);

CREATE INDEX users_username_trgm_idx
  ON auth.users USING gin (username gin_trgm_ops);

CREATE INDEX messages_reply_to_idx
  ON chat.messages (reply_to)
  WHERE reply_to IS NOT NULL;

CREATE INDEX attachments_message_id_idx
  ON chat.attachments (message_id);

CREATE INDEX presence_last_seen_idx
  ON internal.presence (last_seen_at);

CREATE INDEX auth_failures_username_idx
  ON internal.auth_failures (username, failed_at);

RESET ROLE;
