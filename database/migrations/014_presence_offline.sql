-- Presence is heartbeat-only. A leftover session must not look online.

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

GRANT EXECUTE ON FUNCTION chat.set_offline() TO efelant_app;

INSERT INTO internal.schema_migrations (id) VALUES ('014_presence_offline')
ON CONFLICT (id) DO NOTHING;
