SET ROLE efelant_owner;
SET search_path = pg_catalog, public, auth, chat, realtime, internal;

CREATE OR REPLACE FUNCTION internal.setting(p_key text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT s.value FROM internal.app_settings s WHERE s.key = p_key;
$$;

CREATE OR REPLACE FUNCTION internal.token_hash(p_token text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT encode(digest(p_token, 'sha256'), 'hex');
$$;

CREATE OR REPLACE FUNCTION auth.current_user_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_token text;
  v_user_id uuid;
BEGIN
  v_token := nullif(current_setting('efelant.session_token', true), '');
  IF v_token IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT s.user_id
    INTO v_user_id
    FROM auth.sessions s
   WHERE s.token_hash = internal.token_hash(v_token)
     AND s.revoked_at IS NULL
     AND s.expires_at > now();

  RETURN v_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION auth.current_session_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_token text;
  v_session_id uuid;
BEGIN
  v_token := nullif(current_setting('efelant.session_token', true), '');
  IF v_token IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT s.id
    INTO v_session_id
    FROM auth.sessions s
   WHERE s.token_hash = internal.token_hash(v_token)
     AND s.revoked_at IS NULL
     AND s.expires_at > now();

  RETURN v_session_id;
END;
$$;

CREATE OR REPLACE FUNCTION auth.current_device_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_token text;
  v_device_id uuid;
BEGIN
  v_token := nullif(current_setting('efelant.session_token', true), '');
  IF v_token IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT s.device_id
    INTO v_device_id
    FROM auth.sessions s
   WHERE s.token_hash = internal.token_hash(v_token)
     AND s.revoked_at IS NULL
     AND s.expires_at > now();

  RETURN v_device_id;
END;
$$;

CREATE OR REPLACE FUNCTION internal.require_user_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  v_user_id := auth.current_user_id();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'not authenticated'
      USING ERRCODE = '28000';
  END IF;
  RETURN v_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION chat.is_active_member(p_conversation_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM chat.conversation_members m
     WHERE m.conversation_id = p_conversation_id
       AND m.user_id = p_user_id
       AND m.left_at IS NULL
  );
$$;

CREATE OR REPLACE FUNCTION chat.require_active_member(p_conversation_id uuid, p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT chat.is_active_member(p_conversation_id, p_user_id) THEN
    RAISE EXCEPTION 'not a conversation member'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION chat.is_user_online(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM internal.presence p
     WHERE p.user_id = p_user_id
       AND p.status = 'online'
       AND p.last_seen_at > now() - interval '30 seconds'
  );
$$;

CREATE OR REPLACE FUNCTION internal.expire_stale_presence()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid;
BEGIN
  FOR v_user IN
    SELECT DISTINCT user_id
      FROM internal.presence
     WHERE status = 'online'
       AND last_seen_at <= now() - interval '30 seconds'
  LOOP
    UPDATE internal.presence
       SET status = 'offline'
     WHERE user_id = v_user
       AND status = 'online'
       AND last_seen_at <= now() - interval '30 seconds';

    IF NOT chat.is_user_online(v_user) THEN
      PERFORM realtime.emit(
        'presence.updated',
        jsonb_build_object('user_id', v_user, 'online', false)
      );
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION realtime.emit(p_type text, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM pg_notify(
    'efelant_events',
    (jsonb_build_object('type', p_type) || coalesce(p_payload, '{}'::jsonb))::text
  );
END;
$$;

CREATE OR REPLACE FUNCTION internal.issue_session(
  p_user_id uuid,
  p_device_id uuid,
  p_device_name text,
  p_platform text
)
RETURNS TABLE (
  session_id uuid,
  session_token text,
  device_id uuid,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_token text;
  v_hash text;
  v_session_id uuid;
  v_expires timestamptz;
  v_ttl interval;
BEGIN
  v_ttl := internal.setting('session_ttl')::interval;
  v_expires := now() + v_ttl;
  v_token := encode(gen_random_bytes(32), 'hex');
  v_hash := internal.token_hash(v_token);

  INSERT INTO auth.devices (id, user_id, name, platform, last_seen_at)
  VALUES (p_device_id, p_user_id, p_device_name, p_platform, now())
  ON CONFLICT (id) DO UPDATE
    SET name = excluded.name,
        platform = excluded.platform,
        last_seen_at = now()
  WHERE auth.devices.user_id = p_user_id;

  IF NOT EXISTS (
    SELECT 1 FROM auth.devices d WHERE d.id = p_device_id AND d.user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'device belongs to another user'
      USING ERRCODE = '42501';
  END IF;

  UPDATE auth.sessions s
     SET revoked_at = now()
   WHERE s.user_id = p_user_id
     AND s.device_id = p_device_id
     AND s.revoked_at IS NULL;

  INSERT INTO auth.sessions (user_id, device_id, token_hash, expires_at)
  VALUES (p_user_id, p_device_id, v_hash, v_expires)
  RETURNING id INTO v_session_id;

  PERFORM set_config('efelant.session_token', v_token, false);

  session_id := v_session_id;
  session_token := v_token;
  device_id := p_device_id;
  expires_at := v_expires;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION internal.record_auth_failure(p_username text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  INSERT INTO internal.auth_failures (username, failed_at)
  VALUES (p_username, now());
$$;

CREATE OR REPLACE FUNCTION internal.auth_locked(p_username text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT count(*) >= 10
    FROM internal.auth_failures f
   WHERE f.username = p_username
     AND f.failed_at > now() - interval '15 minutes';
$$;

CREATE OR REPLACE FUNCTION internal.purge_expired()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  DELETE FROM auth.sessions
   WHERE expires_at < now()
      OR (revoked_at IS NOT NULL AND revoked_at < now() - interval '7 days');

  PERFORM internal.expire_stale_presence();

  DELETE FROM internal.presence
   WHERE last_seen_at < now() - interval '10 minutes';

  DELETE FROM internal.auth_failures
   WHERE failed_at < now() - interval '1 day';

  DELETE FROM chat.attachments a
   WHERE NOT EXISTS (
     SELECT 1 FROM chat.messages m WHERE m.id = a.message_id
   );
END;
$$;

CREATE OR REPLACE FUNCTION auth.register(
  p_username text,
  p_password text,
  p_display_name text,
  p_device_id uuid,
  p_device_name text,
  p_platform text
)
RETURNS TABLE (
  user_id uuid,
  username text,
  display_name text,
  session_id uuid,
  session_token text,
  device_id uuid,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user_id uuid;
  v_username citext;
  v_session record;
BEGIN
  IF p_username IS NULL OR p_password IS NULL OR p_display_name IS NULL
     OR p_device_id IS NULL OR p_device_name IS NULL OR p_platform IS NULL THEN
    RAISE EXCEPTION 'missing required field'
      USING ERRCODE = '22023';
  END IF;

  IF char_length(p_password) < 8 THEN
    RAISE EXCEPTION 'password must be at least 8 characters'
      USING ERRCODE = '22023';
  END IF;

  v_username := trim(p_username)::citext;

  INSERT INTO auth.users (username, display_name, password_hash)
  VALUES (v_username, trim(p_display_name), crypt(p_password, gen_salt('bf', 10)))
  RETURNING id INTO v_user_id;

  SELECT * INTO v_session
    FROM internal.issue_session(v_user_id, p_device_id, p_device_name, p_platform);

  user_id := v_user_id;
  username := v_username::text;
  display_name := trim(p_display_name);
  session_id := v_session.session_id;
  session_token := v_session.session_token;
  device_id := v_session.device_id;
  expires_at := v_session.expires_at;
  RETURN NEXT;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'username already taken'
      USING ERRCODE = '23505';
END;
$$;

CREATE OR REPLACE FUNCTION auth.login(
  p_username text,
  p_password text,
  p_device_id uuid,
  p_device_name text,
  p_platform text
)
RETURNS TABLE (
  user_id uuid,
  username text,
  display_name text,
  session_id uuid,
  session_token text,
  device_id uuid,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user auth.users%ROWTYPE;
  v_session record;
BEGIN
  PERFORM internal.purge_expired();

  IF p_username IS NULL OR p_password IS NULL OR p_device_id IS NULL THEN
    RAISE EXCEPTION 'missing required field'
      USING ERRCODE = '22023';
  END IF;

  IF internal.auth_locked(p_username) THEN
    RAISE EXCEPTION 'too many failed login attempts'
      USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_user
    FROM auth.users u
   WHERE u.username = trim(p_username)::citext;

  IF v_user.id IS NULL OR v_user.password_hash <> crypt(p_password, v_user.password_hash) THEN
    PERFORM internal.record_auth_failure(trim(p_username));
    RAISE EXCEPTION 'invalid username or password'
      USING ERRCODE = '28P01';
  END IF;

  DELETE FROM internal.auth_failures f WHERE f.username = trim(p_username);

  SELECT * INTO v_session
    FROM internal.issue_session(
      v_user.id,
      p_device_id,
      coalesce(p_device_name, 'device'),
      coalesce(p_platform, 'unknown')
    );

  user_id := v_user.id;
  username := v_user.username::text;
  display_name := v_user.display_name;
  session_id := v_session.session_id;
  session_token := v_session.session_token;
  device_id := v_session.device_id;
  expires_at := v_session.expires_at;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION auth.logout()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_session_id uuid;
BEGIN
  v_session_id := auth.current_session_id();
  IF v_session_id IS NULL THEN
    PERFORM set_config('efelant.session_token', '', false);
    RETURN false;
  END IF;

  PERFORM chat.set_offline();

  UPDATE auth.sessions
     SET revoked_at = now()
   WHERE id = v_session_id
     AND revoked_at IS NULL;

  PERFORM set_config('efelant.session_token', '', false);
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION auth.resume_session(p_token text)
RETURNS TABLE (
  user_id uuid,
  username text,
  display_name text,
  session_id uuid,
  device_id uuid,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_session auth.sessions%ROWTYPE;
  v_user auth.users%ROWTYPE;
BEGIN
  IF p_token IS NULL OR p_token = '' THEN
    RAISE EXCEPTION 'session token required'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_session
    FROM auth.sessions s
   WHERE s.token_hash = internal.token_hash(p_token);

  IF v_session.id IS NULL
     OR v_session.revoked_at IS NOT NULL
     OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'session expired or revoked'
      USING ERRCODE = '28000';
  END IF;

  PERFORM set_config('efelant.session_token', p_token, false);

  UPDATE auth.devices d
     SET last_seen_at = now()
   WHERE d.id = v_session.device_id;

  SELECT * INTO v_user FROM auth.users u WHERE u.id = v_session.user_id;

  user_id := v_user.id;
  username := v_user.username::text;
  display_name := v_user.display_name;
  session_id := v_session.id;
  device_id := v_session.device_id;
  expires_at := v_session.expires_at;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION chat.create_direct_conversation(p_other_user_id uuid)
RETURNS TABLE (
  conversation_id uuid,
  created boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_lo uuid;
  v_hi uuid;
  v_existing uuid;
  v_conversation_id uuid;
BEGIN
  v_me := internal.require_user_id();

  IF p_other_user_id IS NULL OR p_other_user_id = v_me THEN
    RAISE EXCEPTION 'invalid peer'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_other_user_id) THEN
    RAISE EXCEPTION 'user not found'
      USING ERRCODE = 'P0002';
  END IF;

  v_lo := least(v_me, p_other_user_id);
  v_hi := greatest(v_me, p_other_user_id);

  SELECT dp.conversation_id INTO v_existing
    FROM chat.direct_pairs dp
   WHERE dp.user_lo = v_lo AND dp.user_hi = v_hi;

  IF v_existing IS NOT NULL THEN
    UPDATE chat.conversation_members m
       SET left_at = NULL,
           joined_at = CASE WHEN m.left_at IS NULL THEN m.joined_at ELSE now() END
     WHERE m.conversation_id = v_existing
       AND m.user_id = v_me
       AND m.left_at IS NOT NULL;

    conversation_id := v_existing;
    created := false;
    RETURN NEXT;
    RETURN;
  END IF;

  INSERT INTO chat.conversations (type, title, created_by)
  VALUES ('direct', NULL, v_me)
  RETURNING id INTO v_conversation_id;

  INSERT INTO chat.conversation_members (conversation_id, user_id, role)
  VALUES
    (v_conversation_id, v_me, 'member'),
    (v_conversation_id, p_other_user_id, 'member');

  INSERT INTO chat.direct_pairs (user_lo, user_hi, conversation_id)
  VALUES (v_lo, v_hi, v_conversation_id);

  PERFORM realtime.emit(
    'conversation.updated',
    jsonb_build_object('conversation_id', v_conversation_id)
  );

  conversation_id := v_conversation_id;
  created := true;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION chat.create_group(p_title text, p_member_ids uuid[])
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_conversation_id uuid;
  v_member uuid;
BEGIN
  v_me := internal.require_user_id();

  IF p_title IS NULL OR trim(p_title) = '' THEN
    RAISE EXCEPTION 'group title required'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO chat.conversations (type, title, created_by)
  VALUES ('group', trim(p_title), v_me)
  RETURNING id INTO v_conversation_id;

  INSERT INTO chat.conversation_members (conversation_id, user_id, role)
  VALUES (v_conversation_id, v_me, 'admin');

  IF p_member_ids IS NOT NULL THEN
    FOREACH v_member IN ARRAY p_member_ids LOOP
      IF v_member IS NULL OR v_member = v_me THEN
        CONTINUE;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_member) THEN
        CONTINUE;
      END IF;
      INSERT INTO chat.conversation_members (conversation_id, user_id, role)
      VALUES (v_conversation_id, v_member, 'member')
      ON CONFLICT (conversation_id, user_id) DO NOTHING;
    END LOOP;
  END IF;

  PERFORM realtime.emit(
    'conversation.updated',
    jsonb_build_object('conversation_id', v_conversation_id)
  );

  RETURN v_conversation_id;
END;
$$;

CREATE OR REPLACE FUNCTION chat.add_member(p_conversation_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_role chat.conversation_members.role%TYPE;
  v_type chat.conversations.type%TYPE;
BEGIN
  v_me := internal.require_user_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);

  SELECT c.type INTO v_type FROM chat.conversations c WHERE c.id = p_conversation_id;
  IF v_type <> 'group' THEN
    RAISE EXCEPTION 'can only add members to groups'
      USING ERRCODE = '22023';
  END IF;

  SELECT m.role INTO v_role
    FROM chat.conversation_members m
   WHERE m.conversation_id = p_conversation_id AND m.user_id = v_me AND m.left_at IS NULL;

  IF v_role <> 'admin' THEN
    RAISE EXCEPTION 'only admins can add members'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'user not found'
      USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO chat.conversation_members (conversation_id, user_id, role)
  VALUES (p_conversation_id, p_user_id, 'member')
  ON CONFLICT (conversation_id, user_id) DO UPDATE
    SET left_at = NULL,
        joined_at = now(),
        role = 'member';

  UPDATE chat.conversations SET updated_at = now() WHERE id = p_conversation_id;

  PERFORM realtime.emit(
    'conversation.updated',
    jsonb_build_object('conversation_id', p_conversation_id)
  );

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION chat.remove_member(p_conversation_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_role chat.conversation_members.role%TYPE;
  v_type chat.conversations.type%TYPE;
BEGIN
  v_me := internal.require_user_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);

  SELECT c.type INTO v_type FROM chat.conversations c WHERE c.id = p_conversation_id;
  IF v_type <> 'group' THEN
    RAISE EXCEPTION 'can only remove members from groups'
      USING ERRCODE = '22023';
  END IF;

  SELECT m.role INTO v_role
    FROM chat.conversation_members m
   WHERE m.conversation_id = p_conversation_id AND m.user_id = v_me AND m.left_at IS NULL;

  IF v_role <> 'admin' THEN
    RAISE EXCEPTION 'only admins can remove members'
      USING ERRCODE = '42501';
  END IF;

  UPDATE chat.conversation_members
     SET left_at = now()
   WHERE conversation_id = p_conversation_id
     AND user_id = p_user_id
     AND left_at IS NULL;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE chat.conversations SET updated_at = now() WHERE id = p_conversation_id;

  PERFORM realtime.emit(
    'conversation.updated',
    jsonb_build_object('conversation_id', p_conversation_id)
  );

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION chat.leave_conversation(p_conversation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
BEGIN
  v_me := internal.require_user_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);

  UPDATE chat.conversation_members
     SET left_at = now()
   WHERE conversation_id = p_conversation_id
     AND user_id = v_me
     AND left_at IS NULL;

  UPDATE chat.conversations SET updated_at = now() WHERE id = p_conversation_id;

  PERFORM realtime.emit(
    'conversation.updated',
    jsonb_build_object('conversation_id', p_conversation_id)
  );

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION chat.send_message(
  p_conversation_id uuid,
  p_client_id uuid,
  p_type text DEFAULT 'text',
  p_content text DEFAULT NULL,
  p_encrypted_content bytea DEFAULT NULL,
  p_reply_to uuid DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  conversation_id uuid,
  sender_id uuid,
  client_id uuid,
  type text,
  content text,
  reply_to uuid,
  created_at timestamptz,
  edited_at timestamptz,
  deleted_at timestamptz,
  duplicate boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_type chat.messages.type%TYPE;
  v_existing chat.messages%ROWTYPE;
  v_row chat.messages%ROWTYPE;
BEGIN
  v_me := internal.require_user_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);

  IF p_client_id IS NULL THEN
    RAISE EXCEPTION 'client_id required'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_existing
    FROM chat.messages m
   WHERE m.sender_id = v_me AND m.client_id = p_client_id;

  IF v_existing.id IS NOT NULL THEN
    id := v_existing.id;
    conversation_id := v_existing.conversation_id;
    sender_id := v_existing.sender_id;
    client_id := v_existing.client_id;
    type := v_existing.type::text;
    content := v_existing.content;
    reply_to := v_existing.reply_to;
    created_at := v_existing.created_at;
    edited_at := v_existing.edited_at;
    deleted_at := v_existing.deleted_at;
    duplicate := true;
    RETURN NEXT;
    RETURN;
  END IF;

  v_type := coalesce(p_type, 'text')::chat.message_type;

  IF p_reply_to IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM chat.messages r
     WHERE r.id = p_reply_to AND r.conversation_id = p_conversation_id
  ) THEN
    RAISE EXCEPTION 'reply target not found'
      USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO chat.messages (
    conversation_id, sender_id, client_id, type, content, encrypted_content, reply_to
  )
  VALUES (
    p_conversation_id, v_me, p_client_id, v_type, p_content, p_encrypted_content, p_reply_to
  )
  RETURNING * INTO v_row;

  UPDATE chat.conversations c
     SET updated_at = now()
   WHERE c.id = p_conversation_id;

  id := v_row.id;
  conversation_id := v_row.conversation_id;
  sender_id := v_row.sender_id;
  client_id := v_row.client_id;
  type := v_row.type::text;
  content := v_row.content;
  reply_to := v_row.reply_to;
  created_at := v_row.created_at;
  edited_at := v_row.edited_at;
  deleted_at := v_row.deleted_at;
  duplicate := false;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION chat.edit_message(p_message_id uuid, p_content text)
RETURNS chat.messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_row chat.messages%ROWTYPE;
BEGIN
  v_me := internal.require_user_id();

  SELECT * INTO v_row FROM chat.messages m WHERE m.id = p_message_id;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'message not found'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM chat.require_active_member(v_row.conversation_id, v_me);

  IF v_row.sender_id <> v_me THEN
    RAISE EXCEPTION 'cannot edit another user''s message'
      USING ERRCODE = '42501';
  END IF;

  IF v_row.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'cannot edit a deleted message'
      USING ERRCODE = '22023';
  END IF;

  UPDATE chat.messages m
     SET content = p_content,
         edited_at = now()
   WHERE m.id = p_message_id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION chat.delete_message(p_message_id uuid)
RETURNS chat.messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_row chat.messages%ROWTYPE;
BEGIN
  v_me := internal.require_user_id();

  SELECT * INTO v_row FROM chat.messages m WHERE m.id = p_message_id;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'message not found'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM chat.require_active_member(v_row.conversation_id, v_me);

  IF v_row.sender_id <> v_me THEN
    RAISE EXCEPTION 'cannot delete another user''s message'
      USING ERRCODE = '42501';
  END IF;

  UPDATE chat.messages m
     SET deleted_at = now(),
         content = NULL,
         encrypted_content = NULL
   WHERE m.id = p_message_id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

CREATE OR REPLACE FUNCTION chat.message_reactions(p_message_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object('emoji', r.emoji, 'user_id', r.user_id)
      ORDER BY r.created_at
    ),
    '[]'::jsonb
  )
    FROM chat.reactions r
   WHERE r.message_id = p_message_id;
$$;

CREATE OR REPLACE FUNCTION chat.get_conversations()
RETURNS TABLE (
  id uuid,
  type text,
  title text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  peer_user_id uuid,
  peer_username text,
  peer_display_name text,
  peer_online boolean,
  last_message_id uuid,
  last_message_content text,
  last_message_type text,
  last_message_at timestamptz,
  last_message_sender_id uuid,
  last_read_message_id uuid,
  unread_count bigint,
  my_role text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
BEGIN
  v_me := internal.require_user_id();

  RETURN QUERY
  SELECT
    c.id,
    c.type::text,
    CASE
      WHEN c.type = 'direct' THEN peer.display_name
      ELSE c.title
    END AS title,
    c.created_by,
    c.created_at,
    c.updated_at,
    peer.id,
    peer.username::text,
    peer.display_name,
    CASE WHEN peer.id IS NULL THEN false ELSE chat.is_user_online(peer.id) END,
    lm.id,
    CASE WHEN lm.deleted_at IS NOT NULL THEN NULL ELSE lm.content END,
    lm.type::text,
    lm.created_at,
    lm.sender_id,
    cr.last_read_message_id,
    (
      SELECT count(*)
        FROM chat.messages m
       WHERE m.conversation_id = c.id
         AND m.deleted_at IS NULL
         AND m.sender_id <> v_me
         AND (
           cr.last_read_message_id IS NULL
           OR (m.created_at, m.id) > (
             SELECT x.created_at, x.id
               FROM chat.messages x
              WHERE x.id = cr.last_read_message_id
           )
         )
    ),
    me.role::text
  FROM chat.conversation_members me
  JOIN chat.conversations c ON c.id = me.conversation_id
  LEFT JOIN chat.conversation_members other
    ON other.conversation_id = c.id
   AND other.user_id <> v_me
   AND other.left_at IS NULL
   AND c.type = 'direct'
  LEFT JOIN auth.users peer ON peer.id = other.user_id
  LEFT JOIN LATERAL (
    SELECT m.*
      FROM chat.messages m
     WHERE m.conversation_id = c.id
     ORDER BY m.created_at DESC, m.id DESC
     LIMIT 1
  ) lm ON true
  LEFT JOIN chat.conversation_reads cr
    ON cr.conversation_id = c.id AND cr.user_id = v_me
  WHERE me.user_id = v_me
    AND me.left_at IS NULL
  ORDER BY c.updated_at DESC, c.id DESC;
END;
$$;

CREATE OR REPLACE FUNCTION chat.get_messages(
  p_conversation_id uuid,
  p_limit integer DEFAULT 50,
  p_before_created_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  conversation_id uuid,
  sender_id uuid,
  sender_username text,
  sender_display_name text,
  client_id uuid,
  type text,
  content text,
  reply_to uuid,
  created_at timestamptz,
  edited_at timestamptz,
  deleted_at timestamptz,
  reactions jsonb,
  attachment_id uuid,
  attachment_filename text,
  attachment_mime_type text,
  attachment_size bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_limit integer;
BEGIN
  v_me := internal.require_user_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);
  v_limit := greatest(1, least(coalesce(p_limit, 50), 200));

  RETURN QUERY
  SELECT
    m.id,
    m.conversation_id,
    m.sender_id,
    u.username::text,
    u.display_name,
    m.client_id,
    m.type::text,
    CASE WHEN m.deleted_at IS NOT NULL THEN NULL ELSE m.content END,
    m.reply_to,
    m.created_at,
    m.edited_at,
    m.deleted_at,
    chat.message_reactions(m.id),
    a.id,
    a.filename,
    a.mime_type,
    a.size
  FROM chat.messages m
  JOIN auth.users u ON u.id = m.sender_id
  LEFT JOIN LATERAL (
    SELECT att.*
      FROM chat.attachments att
     WHERE att.message_id = m.id
     ORDER BY att.created_at
     LIMIT 1
  ) a ON true
  WHERE m.conversation_id = p_conversation_id
    AND (
      p_before_created_at IS NULL
      OR (m.created_at, m.id) < (p_before_created_at, p_before_id)
    )
  ORDER BY m.created_at DESC, m.id DESC
  LIMIT v_limit;
END;
$$;

CREATE OR REPLACE FUNCTION chat.get_messages_after(
  p_conversation_id uuid,
  p_after_created_at timestamptz,
  p_after_id uuid
)
RETURNS TABLE (
  id uuid,
  conversation_id uuid,
  sender_id uuid,
  sender_username text,
  sender_display_name text,
  client_id uuid,
  type text,
  content text,
  reply_to uuid,
  created_at timestamptz,
  edited_at timestamptz,
  deleted_at timestamptz,
  reactions jsonb,
  attachment_id uuid,
  attachment_filename text,
  attachment_mime_type text,
  attachment_size bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
BEGIN
  v_me := internal.require_user_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);

  IF p_after_created_at IS NULL OR p_after_id IS NULL THEN
    RAISE EXCEPTION 'cursor required'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  SELECT
    m.id,
    m.conversation_id,
    m.sender_id,
    u.username::text,
    u.display_name,
    m.client_id,
    m.type::text,
    CASE WHEN m.deleted_at IS NOT NULL THEN NULL ELSE m.content END,
    m.reply_to,
    m.created_at,
    m.edited_at,
    m.deleted_at,
    chat.message_reactions(m.id),
    a.id,
    a.filename,
    a.mime_type,
    a.size
  FROM chat.messages m
  JOIN auth.users u ON u.id = m.sender_id
  LEFT JOIN LATERAL (
    SELECT att.*
      FROM chat.attachments att
     WHERE att.message_id = m.id
     ORDER BY att.created_at
     LIMIT 1
  ) a ON true
  WHERE m.conversation_id = p_conversation_id
    AND (m.created_at, m.id) > (p_after_created_at, p_after_id)
  ORDER BY m.created_at ASC, m.id ASC
  LIMIT 500;
END;
$$;

CREATE OR REPLACE FUNCTION chat.get_message(p_message_id uuid)
RETURNS TABLE (
  id uuid,
  conversation_id uuid,
  sender_id uuid,
  sender_username text,
  sender_display_name text,
  client_id uuid,
  type text,
  content text,
  reply_to uuid,
  created_at timestamptz,
  edited_at timestamptz,
  deleted_at timestamptz,
  reactions jsonb,
  attachment_id uuid,
  attachment_filename text,
  attachment_mime_type text,
  attachment_size bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_conversation_id uuid;
BEGIN
  v_me := internal.require_user_id();

  SELECT m.conversation_id INTO v_conversation_id
    FROM chat.messages m
   WHERE m.id = p_message_id;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'message not found'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM chat.require_active_member(v_conversation_id, v_me);

  RETURN QUERY
  SELECT
    m.id,
    m.conversation_id,
    m.sender_id,
    u.username::text,
    u.display_name,
    m.client_id,
    m.type::text,
    CASE WHEN m.deleted_at IS NOT NULL THEN NULL ELSE m.content END,
    m.reply_to,
    m.created_at,
    m.edited_at,
    m.deleted_at,
    chat.message_reactions(m.id),
    a.id,
    a.filename,
    a.mime_type,
    a.size
  FROM chat.messages m
  JOIN auth.users u ON u.id = m.sender_id
  LEFT JOIN LATERAL (
    SELECT att.*
      FROM chat.attachments att
     WHERE att.message_id = m.id
     ORDER BY att.created_at
     LIMIT 1
  ) a ON true
  WHERE m.id = p_message_id;
END;
$$;

CREATE OR REPLACE FUNCTION chat.mark_read(p_conversation_id uuid, p_message_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
BEGIN
  v_me := internal.require_user_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);

  IF NOT EXISTS (
    SELECT 1 FROM chat.messages m
     WHERE m.id = p_message_id AND m.conversation_id = p_conversation_id
  ) THEN
    RAISE EXCEPTION 'message not in conversation'
      USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO chat.conversation_reads (conversation_id, user_id, last_read_message_id, updated_at)
  VALUES (p_conversation_id, v_me, p_message_id, now())
  ON CONFLICT (conversation_id, user_id) DO UPDATE
    SET last_read_message_id = excluded.last_read_message_id,
        updated_at = now();

  PERFORM realtime.emit(
    'read.updated',
    jsonb_build_object(
      'conversation_id', p_conversation_id,
      'user_id', v_me,
      'message_id', p_message_id
    )
  );

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION chat.add_reaction(p_message_id uuid, p_emoji text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_conversation_id uuid;
BEGIN
  v_me := internal.require_user_id();

  SELECT m.conversation_id INTO v_conversation_id
    FROM chat.messages m
   WHERE m.id = p_message_id AND m.deleted_at IS NULL;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'message not found'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM chat.require_active_member(v_conversation_id, v_me);

  INSERT INTO chat.reactions (message_id, user_id, emoji)
  VALUES (p_message_id, v_me, p_emoji)
  ON CONFLICT (message_id, user_id, emoji) DO NOTHING;

  PERFORM realtime.emit(
    'reaction.updated',
    jsonb_build_object(
      'conversation_id', v_conversation_id,
      'message_id', p_message_id
    )
  );

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION chat.remove_reaction(p_message_id uuid, p_emoji text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_conversation_id uuid;
BEGIN
  v_me := internal.require_user_id();

  SELECT m.conversation_id INTO v_conversation_id
    FROM chat.messages m
   WHERE m.id = p_message_id;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'message not found'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM chat.require_active_member(v_conversation_id, v_me);

  DELETE FROM chat.reactions r
   WHERE r.message_id = p_message_id
     AND r.user_id = v_me
     AND r.emoji = p_emoji;

  PERFORM realtime.emit(
    'reaction.updated',
    jsonb_build_object(
      'conversation_id', v_conversation_id,
      'message_id', p_message_id
    )
  );

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION chat.upload_attachment(
  p_message_id uuid,
  p_filename text,
  p_mime_type text,
  p_data bytea
)
RETURNS TABLE (
  id uuid,
  message_id uuid,
  filename text,
  mime_type text,
  size bigint,
  sha256 bytea,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_message chat.messages%ROWTYPE;
  v_size bigint;
  v_max bigint;
  v_row chat.attachments%ROWTYPE;
BEGIN
  v_me := internal.require_user_id();

  SELECT * INTO v_message FROM chat.messages m WHERE m.id = p_message_id;
  IF v_message.id IS NULL THEN
    RAISE EXCEPTION 'message not found'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM chat.require_active_member(v_message.conversation_id, v_me);

  IF v_message.sender_id <> v_me THEN
    RAISE EXCEPTION 'cannot attach to another user''s message'
      USING ERRCODE = '42501';
  END IF;

  IF p_data IS NULL THEN
    RAISE EXCEPTION 'attachment data required'
      USING ERRCODE = '22023';
  END IF;

  v_size := octet_length(p_data);
  v_max := internal.setting('max_attachment_bytes')::bigint;

  IF v_size > v_max THEN
    RAISE EXCEPTION 'attachment exceeds maximum size of % bytes', v_max
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO chat.attachments (message_id, filename, mime_type, size, sha256, data)
  VALUES (
    p_message_id,
    p_filename,
    p_mime_type,
    v_size,
    digest(p_data, 'sha256'),
    p_data
  )
  RETURNING * INTO v_row;

  PERFORM realtime.emit(
    'message.updated',
    jsonb_build_object(
      'conversation_id', v_message.conversation_id,
      'message_id', p_message_id
    )
  );

  id := v_row.id;
  message_id := v_row.message_id;
  filename := v_row.filename;
  mime_type := v_row.mime_type;
  size := v_row.size;
  sha256 := v_row.sha256;
  created_at := v_row.created_at;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION chat.get_attachment(p_attachment_id uuid)
RETURNS TABLE (
  id uuid,
  message_id uuid,
  filename text,
  mime_type text,
  size bigint,
  sha256 bytea,
  data bytea,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_conversation_id uuid;
BEGIN
  v_me := internal.require_user_id();

  SELECT m.conversation_id INTO v_conversation_id
    FROM chat.attachments a
    JOIN chat.messages m ON m.id = a.message_id
   WHERE a.id = p_attachment_id;

  IF v_conversation_id IS NULL THEN
    RAISE EXCEPTION 'attachment not found'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM chat.require_active_member(v_conversation_id, v_me);

  RETURN QUERY
  SELECT a.id, a.message_id, a.filename, a.mime_type, a.size, a.sha256, a.data, a.created_at
    FROM chat.attachments a
   WHERE a.id = p_attachment_id;
END;
$$;

CREATE OR REPLACE FUNCTION chat.search_users(p_query text)
RETURNS TABLE (
  id uuid,
  username text,
  display_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_q text;
BEGIN
  v_me := internal.require_user_id();
  v_q := trim(coalesce(p_query, ''));

  IF char_length(v_q) < 1 THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT u.id, u.username::text, u.display_name
    FROM auth.users u
   WHERE u.id <> v_me
     AND (
       u.username ILIKE ('%' || v_q || '%')
       OR u.display_name ILIKE ('%' || v_q || '%')
     )
   ORDER BY similarity(u.username::text, v_q) DESC, u.username
   LIMIT 20;
END;
$$;

CREATE OR REPLACE FUNCTION chat.heartbeat()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_device uuid;
  v_was_online boolean;
BEGIN
  v_me := internal.require_user_id();
  v_device := auth.current_device_id();

  PERFORM internal.purge_expired();

  v_was_online := chat.is_user_online(v_me);

  INSERT INTO internal.presence (user_id, device_id, last_seen_at, status)
  VALUES (v_me, v_device, now(), 'online')
  ON CONFLICT (user_id, device_id) DO UPDATE
    SET last_seen_at = now(),
        status = 'online';

  UPDATE auth.devices SET last_seen_at = now() WHERE id = v_device;

  IF NOT v_was_online THEN
    PERFORM realtime.emit(
      'presence.updated',
      jsonb_build_object('user_id', v_me, 'online', true)
    );
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION chat.set_offline()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_device uuid;
BEGIN
  v_me := internal.require_user_id();
  v_device := auth.current_device_id();

  UPDATE internal.presence
     SET status = 'offline',
         last_seen_at = now()
   WHERE user_id = v_me
     AND device_id = v_device
     AND status = 'online';

  IF NOT FOUND THEN
    RETURN chat.is_user_online(v_me);
  END IF;

  IF NOT chat.is_user_online(v_me) THEN
    PERFORM realtime.emit(
      'presence.updated',
      jsonb_build_object('user_id', v_me, 'online', false)
    );
  END IF;

  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION chat.set_typing(p_conversation_id uuid, p_is_typing boolean)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
BEGIN
  v_me := internal.require_user_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);

  PERFORM realtime.emit(
    CASE WHEN p_is_typing THEN 'typing.started' ELSE 'typing.stopped' END,
    jsonb_build_object(
      'conversation_id', p_conversation_id,
      'user_id', v_me
    )
  );

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION chat.current_device()
RETURNS TABLE (
  id uuid,
  name text,
  platform text,
  created_at timestamptz,
  last_seen_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_device uuid;
BEGIN
  PERFORM internal.require_user_id();
  v_device := auth.current_device_id();

  RETURN QUERY
  SELECT d.id, d.name, d.platform, d.created_at, d.last_seen_at
    FROM auth.devices d
   WHERE d.id = v_device;
END;
$$;

RESET ROLE;
