CREATE SCHEMA auth AUTHORIZATION efelant_owner;
CREATE SCHEMA chat AUTHORIZATION efelant_owner;
CREATE SCHEMA realtime AUTHORIZATION efelant_owner;
CREATE SCHEMA internal AUTHORIZATION efelant_owner;

GRANT USAGE ON SCHEMA auth TO efelant_app;
GRANT USAGE ON SCHEMA chat TO efelant_app;
GRANT USAGE ON SCHEMA realtime TO efelant_app;

REVOKE ALL ON SCHEMA internal FROM PUBLIC;
REVOKE ALL ON SCHEMA internal FROM efelant_app;

GRANT USAGE ON SCHEMA auth TO efelant_migrator;
GRANT USAGE ON SCHEMA chat TO efelant_migrator;
GRANT USAGE ON SCHEMA realtime TO efelant_migrator;
GRANT USAGE ON SCHEMA internal TO efelant_migrator;
GRANT CREATE ON SCHEMA auth, chat, realtime, internal TO efelant_migrator;

SET ROLE efelant_owner;
SET search_path = pg_catalog, public;

CREATE TYPE chat.conversation_type AS ENUM ('direct', 'group');
CREATE TYPE chat.member_role AS ENUM ('member', 'admin');
CREATE TYPE chat.message_type AS ENUM ('text', 'image', 'file', 'system');

CREATE TABLE auth.users (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  username public.citext NOT NULL,
  display_name text NOT NULL,
  password_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT users_username_len CHECK (char_length(username::text) BETWEEN 3 AND 32),
  CONSTRAINT users_username_format CHECK (username::text ~ '^[a-zA-Z][a-zA-Z0-9_]*$'),
  CONSTRAINT users_display_name_len CHECK (char_length(display_name) BETWEEN 1 AND 64)
);

CREATE UNIQUE INDEX users_username_key ON auth.users (username);

CREATE TABLE auth.devices (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  name text NOT NULL,
  platform text NOT NULL,
  push_token text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT devices_name_len CHECK (char_length(name) BETWEEN 1 AND 64),
  CONSTRAINT devices_platform_len CHECK (char_length(platform) BETWEEN 1 AND 32)
);

CREATE TABLE auth.device_keys (
  device_id uuid PRIMARY KEY REFERENCES auth.devices (id) ON DELETE CASCADE,
  identity_public_key bytea NOT NULL,
  signed_prekey bytea,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE auth.sessions (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES auth.devices (id) ON DELETE CASCADE,
  token_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  CONSTRAINT sessions_expires_after_create CHECK (expires_at > created_at)
);

CREATE TABLE chat.conversations (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  type chat.conversation_type NOT NULL,
  title text,
  created_by uuid NOT NULL REFERENCES auth.users (id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT conversations_title_len CHECK (title IS NULL OR char_length(title) BETWEEN 1 AND 80),
  CONSTRAINT conversations_direct_no_title CHECK (type <> 'direct' OR title IS NULL),
  CONSTRAINT conversations_group_has_title CHECK (type <> 'group' OR title IS NOT NULL)
);

CREATE TABLE chat.conversation_members (
  conversation_id uuid NOT NULL REFERENCES chat.conversations (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  role chat.member_role NOT NULL DEFAULT 'member',
  joined_at timestamptz NOT NULL DEFAULT now(),
  left_at timestamptz,
  PRIMARY KEY (conversation_id, user_id)
);

CREATE TABLE chat.direct_pairs (
  user_lo uuid NOT NULL REFERENCES auth.users (id),
  user_hi uuid NOT NULL REFERENCES auth.users (id),
  conversation_id uuid NOT NULL UNIQUE REFERENCES chat.conversations (id) ON DELETE CASCADE,
  PRIMARY KEY (user_lo, user_hi),
  CONSTRAINT direct_pairs_ordered CHECK (user_lo < user_hi)
);

CREATE TABLE chat.messages (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  conversation_id uuid NOT NULL REFERENCES chat.conversations (id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES auth.users (id),
  client_id uuid NOT NULL,
  type chat.message_type NOT NULL DEFAULT 'text',
  content text,
  encrypted_content bytea,
  reply_to uuid REFERENCES chat.messages (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  edited_at timestamptz,
  deleted_at timestamptz,
  CONSTRAINT messages_content_len CHECK (content IS NULL OR char_length(content) <= 8000),
  CONSTRAINT messages_has_payload CHECK (
    deleted_at IS NOT NULL
    OR content IS NOT NULL
    OR encrypted_content IS NOT NULL
    OR type IN ('image', 'file', 'system')
  ),
  UNIQUE (sender_id, client_id)
);

CREATE TABLE chat.attachments (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  message_id uuid NOT NULL REFERENCES chat.messages (id) ON DELETE CASCADE,
  filename text NOT NULL,
  mime_type text NOT NULL,
  size bigint NOT NULL,
  sha256 bytea NOT NULL,
  data bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT attachments_size_positive CHECK (size > 0),
  CONSTRAINT attachments_size_hard_max CHECK (size <= 20971520),
  CONSTRAINT attachments_filename_len CHECK (char_length(filename) BETWEEN 1 AND 255),
  CONSTRAINT attachments_mime_len CHECK (char_length(mime_type) BETWEEN 1 AND 127)
);

CREATE TABLE chat.conversation_reads (
  conversation_id uuid NOT NULL REFERENCES chat.conversations (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  last_read_message_id uuid NOT NULL REFERENCES chat.messages (id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_id)
);

CREATE TABLE chat.reactions (
  message_id uuid NOT NULL REFERENCES chat.messages (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  emoji text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id, emoji),
  CONSTRAINT reactions_emoji_len CHECK (char_length(emoji) BETWEEN 1 AND 16)
);

CREATE UNLOGGED TABLE internal.presence (
  user_id uuid NOT NULL,
  device_id uuid NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL DEFAULT 'online',
  PRIMARY KEY (user_id, device_id),
  CONSTRAINT presence_status_known CHECK (status IN ('online', 'away', 'offline'))
);

CREATE UNLOGGED TABLE internal.auth_failures (
  username text NOT NULL,
  failed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE internal.app_settings (
  key text PRIMARY KEY,
  value text NOT NULL
);

INSERT INTO internal.app_settings (key, value) VALUES
  ('max_attachment_bytes', '10485760'),
  ('session_ttl', '30 days'),
  ('presence_online_interval', '30 seconds');

RESET ROLE;
