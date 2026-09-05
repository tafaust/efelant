SET ROLE efelant_owner;
SET search_path = pg_catalog, public, auth, chat, realtime, internal;

CREATE TABLE IF NOT EXISTS chat.conversation_deliveries (
  conversation_id uuid NOT NULL REFERENCES chat.conversations (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  last_delivered_message_id uuid NOT NULL REFERENCES chat.messages (id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_id)
);

CREATE OR REPLACE FUNCTION chat._message_is_newer(
  p_conversation_id uuid,
  p_candidate uuid,
  p_current uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT p_current IS NULL
      OR (
        SELECT (c.created_at, c.id) > (cur.created_at, cur.id)
          FROM chat.messages c
          JOIN chat.messages cur ON cur.id = p_current
         WHERE c.id = p_candidate
           AND c.conversation_id = p_conversation_id
           AND cur.conversation_id = p_conversation_id
      );
$$;

CREATE OR REPLACE FUNCTION chat.mark_delivered(
  p_conversation_id uuid,
  p_message_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_current uuid;
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

  SELECT d.last_delivered_message_id INTO v_current
    FROM chat.conversation_deliveries d
   WHERE d.conversation_id = p_conversation_id
     AND d.user_id = v_me;

  IF NOT chat._message_is_newer(p_conversation_id, p_message_id, v_current) THEN
    RETURN true;
  END IF;

  INSERT INTO chat.conversation_deliveries (
    conversation_id, user_id, last_delivered_message_id, updated_at
  )
  VALUES (p_conversation_id, v_me, p_message_id, now())
  ON CONFLICT (conversation_id, user_id) DO UPDATE
    SET last_delivered_message_id = excluded.last_delivered_message_id,
        updated_at = now();

  PERFORM realtime.emit(
    'receipt.updated',
    jsonb_build_object(
      'conversation_id', p_conversation_id,
      'user_id', v_me,
      'message_id', p_message_id,
      'kind', 'delivered'
    )
  );

  RETURN true;
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

  PERFORM chat.mark_delivered(p_conversation_id, p_message_id);

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

CREATE OR REPLACE FUNCTION chat.get_peer_receipts(p_conversation_id uuid)
RETURNS TABLE (
  last_delivered_message_id uuid,
  last_read_message_id uuid
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

  RETURN QUERY
  SELECT
    (
      SELECT d.last_delivered_message_id
        FROM chat.conversation_deliveries d
        JOIN chat.conversation_members m
          ON m.conversation_id = d.conversation_id
         AND m.user_id = d.user_id
         AND m.left_at IS NULL
        JOIN chat.messages msg ON msg.id = d.last_delivered_message_id
       WHERE d.conversation_id = p_conversation_id
         AND d.user_id <> v_me
       ORDER BY msg.created_at DESC, msg.id DESC
       LIMIT 1
    ),
    (
      SELECT r.last_read_message_id
        FROM chat.conversation_reads r
        JOIN chat.conversation_members m
          ON m.conversation_id = r.conversation_id
         AND m.user_id = r.user_id
         AND m.left_at IS NULL
        JOIN chat.messages msg ON msg.id = r.last_read_message_id
       WHERE r.conversation_id = p_conversation_id
         AND r.user_id <> v_me
       ORDER BY msg.created_at DESC, msg.id DESC
       LIMIT 1
    );
END;
$$;

CREATE OR REPLACE FUNCTION chat.put_conversation_key_wrap(
  p_conversation_id uuid,
  p_device_id uuid,
  p_wrapped_key bytea
)
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

  IF p_wrapped_key IS NULL OR octet_length(p_wrapped_key) < 48 THEN
    RAISE EXCEPTION 'invalid wrapped key'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM chat.conversation_members m
      JOIN auth.devices d ON d.user_id = m.user_id
     WHERE m.conversation_id = p_conversation_id
       AND m.left_at IS NULL
       AND d.id = p_device_id
  ) THEN
    RAISE EXCEPTION 'device is not a conversation member'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO chat.conversation_key_wraps (conversation_id, device_id, wrapped_key)
  VALUES (p_conversation_id, p_device_id, p_wrapped_key)
  ON CONFLICT (conversation_id, device_id) DO UPDATE
    SET wrapped_key = excluded.wrapped_key,
        created_at = now();

  PERFORM realtime.emit(
    'key.wrap.updated',
    jsonb_build_object(
      'conversation_id', p_conversation_id,
      'device_id', p_device_id
    )
  );

  RETURN true;
END;
$$;

DROP FUNCTION IF EXISTS chat.get_conversations();

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
  my_role text,
  peer_last_read_message_id uuid,
  peer_last_delivered_message_id uuid
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
    me.role::text,
    peer_cr.last_read_message_id,
    peer_d.last_delivered_message_id
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
  LEFT JOIN chat.conversation_reads peer_cr
    ON peer_cr.conversation_id = c.id AND peer_cr.user_id = peer.id
  LEFT JOIN chat.conversation_deliveries peer_d
    ON peer_d.conversation_id = c.id AND peer_d.user_id = peer.id
  WHERE me.user_id = v_me
    AND me.left_at IS NULL
  ORDER BY c.updated_at DESC, c.id DESC;
END;
$$;

RESET ROLE;

GRANT EXECUTE ON FUNCTION chat.mark_delivered(uuid, uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.mark_read(uuid, uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.get_peer_receipts(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.put_conversation_key_wrap(uuid, uuid, bytea) TO efelant_app;
CREATE OR REPLACE FUNCTION realtime.notify_message_created()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM realtime.emit(
    'message.created',
    jsonb_build_object(
      'conversation_id', NEW.conversation_id,
      'message_id', NEW.id,
      'user_id', NEW.sender_id
    )
  );
  RETURN NEW;
END;
$$;

GRANT EXECUTE ON FUNCTION chat.get_conversations() TO efelant_app;
