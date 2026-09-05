SET ROLE efelant_owner;
SET search_path = pg_catalog, public, auth, chat, realtime, internal;

CREATE OR REPLACE FUNCTION chat.get_conversation_key_wraps(p_conversation_id uuid)
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
BEGIN
  v_me := internal.require_user_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);

  RETURN QUERY
  SELECT w.device_id, w.wrapped_key
    FROM chat.conversation_key_wraps w
   WHERE w.conversation_id = p_conversation_id;
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
  v_changed boolean := false;
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
        created_at = now()
  WHERE chat.conversation_key_wraps.wrapped_key IS DISTINCT FROM excluded.wrapped_key
  RETURNING true INTO v_changed;

  IF v_changed THEN
    PERFORM realtime.emit(
      'key.wrap.updated',
      jsonb_build_object(
        'conversation_id', p_conversation_id,
        'device_id', p_device_id
      )
    );
  END IF;

  RETURN true;
END;
$$;

RESET ROLE;

GRANT EXECUTE ON FUNCTION chat.get_conversation_key_wraps(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION chat.put_conversation_key_wrap(uuid, uuid, bytea) TO efelant_app;
