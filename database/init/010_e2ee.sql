SET ROLE efelant_owner;
SET search_path = pg_catalog, public, auth, chat, realtime, internal;

CREATE TABLE IF NOT EXISTS chat.conversation_key_wraps (
  conversation_id uuid NOT NULL REFERENCES chat.conversations (id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES auth.devices (id) ON DELETE CASCADE,
  wrapped_key bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, device_id)
);

ALTER TABLE chat.conversation_key_wraps ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.conversation_key_wraps FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS conversation_key_wraps_member ON chat.conversation_key_wraps;
CREATE POLICY conversation_key_wraps_member ON chat.conversation_key_wraps
  USING (internal.visible_conversation(auth.current_user_id(), conversation_id));

CREATE OR REPLACE FUNCTION auth.publish_device_key(p_identity_public_key bytea)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_device uuid;
BEGIN
  PERFORM internal.require_user_id();
  v_device := auth.current_device_id();
  IF v_device IS NULL OR p_identity_public_key IS NULL OR octet_length(p_identity_public_key) <> 32 THEN
    RAISE EXCEPTION 'invalid device key'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO auth.device_keys (device_id, identity_public_key)
  VALUES (v_device, p_identity_public_key)
  ON CONFLICT (device_id) DO UPDATE
    SET identity_public_key = excluded.identity_public_key,
        created_at = now();

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION auth.device_public_keys(p_user_id uuid)
RETURNS TABLE (
  device_id uuid,
  identity_public_key bytea
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM internal.require_user_id();
  RETURN QUERY
  SELECT d.id, k.identity_public_key
    FROM auth.devices d
    JOIN auth.device_keys k ON k.device_id = d.id
   WHERE d.user_id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION chat.member_device_keys(p_conversation_id uuid)
RETURNS TABLE (
  user_id uuid,
  device_id uuid,
  identity_public_key bytea
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
  SELECT d.user_id, d.id, k.identity_public_key
    FROM chat.conversation_members m
    JOIN auth.devices d ON d.user_id = m.user_id
    JOIN auth.device_keys k ON k.device_id = d.id
   WHERE m.conversation_id = p_conversation_id
     AND m.left_at IS NULL;
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

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION chat.has_conversation_key_wraps(p_conversation_id uuid)
RETURNS boolean
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
  RETURN EXISTS (
    SELECT 1
      FROM chat.conversation_key_wraps w
     WHERE w.conversation_id = p_conversation_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION chat.get_conversation_key_wrap(p_conversation_id uuid)
RETURNS TABLE (
  device_id uuid,
  wrapped_key bytea
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_device uuid;
BEGIN
  v_me := internal.require_user_id();
  v_device := auth.current_device_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);

  RETURN QUERY
  SELECT w.device_id, w.wrapped_key
    FROM chat.conversation_key_wraps w
   WHERE w.conversation_id = p_conversation_id
     AND w.device_id = v_device;
END;
$$;

CREATE OR REPLACE FUNCTION chat.get_ciphertexts(p_conversation_id uuid)
RETURNS TABLE (
  message_id uuid,
  encrypted_content bytea
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
  SELECT m.id, m.encrypted_content
    FROM chat.messages m
   WHERE m.conversation_id = p_conversation_id
     AND m.encrypted_content IS NOT NULL
     AND m.deleted_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION chat.edit_encrypted_message(
  p_message_id uuid,
  p_encrypted_content bytea
)
RETURNS boolean
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

  UPDATE chat.messages
     SET encrypted_content = p_encrypted_content,
         content = NULL,
         edited_at = now()
   WHERE id = p_message_id;

  RETURN true;
END;
$$;

RESET ROLE;

REVOKE ALL ON TABLE chat.conversation_key_wraps FROM PUBLIC, efelant_app;
GRANT EXECUTE ON FUNCTION auth.publish_device_key(bytea) TO efelant_app;
GRANT EXECUTE ON FUNCTION auth.device_public_keys(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.member_device_keys(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.put_conversation_key_wrap(uuid, uuid, bytea) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.has_conversation_key_wraps(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.get_conversation_key_wrap(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.get_ciphertexts(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.edit_encrypted_message(uuid, bytea) TO efelant_app;
