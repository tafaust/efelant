-- Efelant platform layer: tenants, contexts, durable events.
-- Incremental. Existing standalone messenger keeps working via the
-- built-in "standalone" tenant. Function signatures used by Flutter stay.

CREATE SCHEMA IF NOT EXISTS platform AUTHORIZATION efelant_owner;
CREATE SCHEMA IF NOT EXISTS efelant AUTHORIZATION efelant_owner;

GRANT USAGE ON SCHEMA platform TO efelant_app, efelant_migrator;
GRANT USAGE ON SCHEMA efelant TO efelant_app, efelant_migrator, PUBLIC;
GRANT CREATE ON SCHEMA platform, efelant TO efelant_migrator;

SET ROLE efelant_owner;
SET search_path = pg_catalog, public;

CREATE TABLE IF NOT EXISTS internal.schema_migrations (
  id text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

ALTER TYPE chat.conversation_type ADD VALUE IF NOT EXISTS 'context';

CREATE TABLE IF NOT EXISTS platform.tenants (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  slug public.citext NOT NULL,
  name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tenants_slug_len CHECK (char_length(slug::text) BETWEEN 1 AND 64),
  CONSTRAINT tenants_slug_format CHECK (slug::text ~ '^[a-z][a-z0-9_-]*$'),
  CONSTRAINT tenants_name_len CHECK (char_length(name) BETWEEN 1 AND 80)
);

CREATE UNIQUE INDEX IF NOT EXISTS tenants_slug_key ON platform.tenants (slug);

CREATE TABLE IF NOT EXISTS platform.tenant_members (
  tenant_id uuid NOT NULL REFERENCES platform.tenants (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'member',
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, user_id),
  CONSTRAINT tenant_members_role_known CHECK (role IN ('owner', 'admin', 'member'))
);

CREATE TABLE IF NOT EXISTS platform.contexts (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id uuid NOT NULL REFERENCES platform.tenants (id) ON DELETE CASCADE,
  type text NOT NULL,
  external_id text NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  conversation_id uuid REFERENCES chat.conversations (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contexts_type_len CHECK (char_length(type) BETWEEN 1 AND 64),
  CONSTRAINT contexts_type_format CHECK (type ~ '^[a-z][a-z0-9_]*$'),
  CONSTRAINT contexts_external_id_len CHECK (char_length(external_id) BETWEEN 1 AND 128),
  UNIQUE (tenant_id, type, external_id)
);

CREATE TABLE IF NOT EXISTS platform.conversation_sequences (
  conversation_id uuid PRIMARY KEY REFERENCES chat.conversations (id) ON DELETE CASCADE,
  last_sequence bigint NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS platform.events (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id uuid NOT NULL REFERENCES platform.tenants (id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES chat.conversations (id) ON DELETE CASCADE,
  sequence bigint NOT NULL,
  type text NOT NULL,
  actor_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT events_sequence_positive CHECK (sequence > 0),
  CONSTRAINT events_type_len CHECK (char_length(type) BETWEEN 1 AND 80),
  UNIQUE (conversation_id, sequence)
);

CREATE INDEX IF NOT EXISTS events_tenant_created_idx
  ON platform.events (tenant_id, created_at);
CREATE INDEX IF NOT EXISTS events_conversation_seq_idx
  ON platform.events (conversation_id, sequence);

DO $$
DECLARE
  v_standalone uuid;
BEGIN
  SELECT id INTO v_standalone FROM platform.tenants WHERE slug = 'standalone';
  IF v_standalone IS NULL THEN
    INSERT INTO platform.tenants (slug, name)
    VALUES ('standalone', 'Efelant')
    RETURNING id INTO v_standalone;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'chat' AND table_name = 'conversations' AND column_name = 'tenant_id'
  ) THEN
    ALTER TABLE chat.conversations ADD COLUMN tenant_id uuid;
  END IF;

  UPDATE chat.conversations SET tenant_id = v_standalone WHERE tenant_id IS NULL;

  ALTER TABLE chat.conversations ALTER COLUMN tenant_id SET NOT NULL;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'conversations_tenant_fkey'
  ) THEN
    ALTER TABLE chat.conversations
      ADD CONSTRAINT conversations_tenant_fkey
      FOREIGN KEY (tenant_id) REFERENCES platform.tenants (id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'chat' AND table_name = 'direct_pairs' AND column_name = 'tenant_id'
  ) THEN
    ALTER TABLE chat.direct_pairs ADD COLUMN tenant_id uuid;
  END IF;

  UPDATE chat.direct_pairs dp
     SET tenant_id = c.tenant_id
    FROM chat.conversations c
   WHERE dp.conversation_id = c.id
     AND dp.tenant_id IS NULL;

  UPDATE chat.direct_pairs SET tenant_id = v_standalone WHERE tenant_id IS NULL;
  ALTER TABLE chat.direct_pairs ALTER COLUMN tenant_id SET NOT NULL;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'direct_pairs_tenant_fkey'
  ) THEN
    ALTER TABLE chat.direct_pairs
      ADD CONSTRAINT direct_pairs_tenant_fkey
      FOREIGN KEY (tenant_id) REFERENCES platform.tenants (id);
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'chat.direct_pairs'::regclass AND contype = 'p'
       AND NOT EXISTS (
         SELECT 1 FROM pg_attribute a
         JOIN pg_constraint c ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
         WHERE c.conrelid = 'chat.direct_pairs'::regclass AND c.contype = 'p'
           AND a.attname = 'tenant_id'
       )
  ) THEN
    ALTER TABLE chat.direct_pairs DROP CONSTRAINT direct_pairs_pkey;
    ALTER TABLE chat.direct_pairs ADD PRIMARY KEY (tenant_id, user_lo, user_hi);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'auth' AND table_name = 'sessions' AND column_name = 'tenant_id'
  ) THEN
    ALTER TABLE auth.sessions ADD COLUMN tenant_id uuid REFERENCES platform.tenants (id);
  END IF;

  ALTER TABLE chat.conversations ALTER COLUMN created_by DROP NOT NULL;

  INSERT INTO platform.tenant_members (tenant_id, user_id, role)
  SELECT v_standalone, u.id, 'member'
    FROM auth.users u
   WHERE NOT EXISTS (
     SELECT 1 FROM platform.tenant_members tm
      WHERE tm.tenant_id = v_standalone AND tm.user_id = u.id
   );

  INSERT INTO platform.conversation_sequences (conversation_id, last_sequence)
  SELECT c.id, 0
    FROM chat.conversations c
   WHERE NOT EXISTS (
     SELECT 1 FROM platform.conversation_sequences s WHERE s.conversation_id = c.id
   );
END
$$;

CREATE INDEX IF NOT EXISTS conversations_tenant_idx ON chat.conversations (tenant_id);
CREATE INDEX IF NOT EXISTS tenant_members_user_idx ON platform.tenant_members (user_id);

CREATE OR REPLACE FUNCTION auth.current_tenant_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_raw text;
  v_tenant uuid;
  v_user uuid;
BEGIN
  v_raw := nullif(current_setting('efelant.tenant_id', true), '');
  IF v_raw IS NOT NULL THEN
    BEGIN
      v_tenant := v_raw::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_tenant := NULL;
    END;
    IF v_tenant IS NOT NULL THEN
      RETURN v_tenant;
    END IF;
  END IF;

  v_user := auth.current_user_id();
  IF v_user IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT tm.tenant_id INTO v_tenant
    FROM platform.tenant_members tm
    JOIN platform.tenants t ON t.id = tm.tenant_id
   WHERE tm.user_id = v_user
   ORDER BY CASE WHEN t.slug = 'standalone' THEN 0 ELSE 1 END, t.created_at
   LIMIT 1;

  RETURN v_tenant;
END;
$$;

CREATE OR REPLACE FUNCTION internal.is_tenant_member(p_tenant_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT p_tenant_id IS NOT NULL
     AND p_user_id IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM platform.tenant_members tm
        WHERE tm.tenant_id = p_tenant_id AND tm.user_id = p_user_id
     );
$$;

CREATE OR REPLACE FUNCTION internal.require_tenant_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_tenant uuid;
  v_user uuid;
BEGIN
  v_user := internal.require_user_id();
  v_tenant := auth.current_tenant_id();
  IF v_tenant IS NULL OR NOT internal.is_tenant_member(v_tenant, v_user) THEN
    RAISE EXCEPTION 'tenant required'
      USING ERRCODE = '42501';
  END IF;
  RETURN v_tenant;
END;
$$;

CREATE OR REPLACE FUNCTION internal.bind_default_tenant(p_user_id uuid, p_session_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  SELECT t.id INTO v_tenant
    FROM platform.tenants t
   WHERE t.slug = 'standalone';

  IF v_tenant IS NULL THEN
    INSERT INTO platform.tenants (slug, name)
    VALUES ('standalone', 'Efelant')
    RETURNING id INTO v_tenant;
  END IF;

  INSERT INTO platform.tenant_members (tenant_id, user_id, role)
  VALUES (v_tenant, p_user_id, 'member')
  ON CONFLICT (tenant_id, user_id) DO NOTHING;

  SELECT tm.tenant_id INTO v_tenant
    FROM platform.tenant_members tm
    JOIN platform.tenants t ON t.id = tm.tenant_id
   WHERE tm.user_id = p_user_id
   ORDER BY CASE WHEN t.slug = 'standalone' THEN 0 ELSE 1 END, t.created_at
   LIMIT 1;

  PERFORM set_config('efelant.tenant_id', v_tenant::text, false);

  IF p_session_id IS NOT NULL THEN
    UPDATE auth.sessions SET tenant_id = v_tenant WHERE id = p_session_id;
  END IF;

  RETURN v_tenant;
END;
$$;

CREATE OR REPLACE FUNCTION auth.select_tenant(p_tenant_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid;
  v_session uuid;
BEGIN
  v_user := internal.require_user_id();
  IF NOT internal.is_tenant_member(p_tenant_id, v_user) THEN
    RAISE EXCEPTION 'not a tenant member'
      USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('efelant.tenant_id', p_tenant_id::text, false);
  v_session := auth.current_session_id();
  IF v_session IS NOT NULL THEN
    UPDATE auth.sessions SET tenant_id = p_tenant_id WHERE id = v_session;
  END IF;
  RETURN p_tenant_id;
END;
$$;

CREATE OR REPLACE FUNCTION auth.list_tenants()
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  role text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid;
BEGIN
  v_user := internal.require_user_id();
  RETURN QUERY
  SELECT t.id, t.slug::text, t.name, tm.role
    FROM platform.tenant_members tm
    JOIN platform.tenants t ON t.id = tm.tenant_id
   WHERE tm.user_id = v_user
   ORDER BY t.name;
END;
$$;

CREATE OR REPLACE FUNCTION platform.create_tenant(p_slug text, p_name text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid;
  v_id uuid;
BEGIN
  v_user := auth.current_user_id();
  INSERT INTO platform.tenants (slug, name)
  VALUES (trim(p_slug)::citext, trim(p_name))
  RETURNING id INTO v_id;

  IF v_user IS NOT NULL THEN
    INSERT INTO platform.tenant_members (tenant_id, user_id, role)
    VALUES (v_id, v_user, 'owner');
    PERFORM set_config('efelant.tenant_id', v_id::text, false);
  END IF;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION platform.add_tenant_member(p_tenant_id uuid, p_user_id uuid, p_role text DEFAULT 'member')
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid;
  v_role text;
BEGIN
  v_actor := auth.current_user_id();
  IF current_user = 'efelant_app' THEN
    IF v_actor IS NULL THEN
      RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
    END IF;
    SELECT tm.role INTO v_role
      FROM platform.tenant_members tm
     WHERE tm.tenant_id = p_tenant_id AND tm.user_id = v_actor;
    IF v_role IS NULL OR v_role NOT IN ('owner', 'admin') THEN
      RAISE EXCEPTION 'only tenant admins can add members'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  INSERT INTO platform.tenant_members (tenant_id, user_id, role)
  VALUES (p_tenant_id, p_user_id, coalesce(nullif(p_role, ''), 'member'))
  ON CONFLICT (tenant_id, user_id) DO UPDATE SET role = excluded.role;
  RETURN true;
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
      JOIN chat.conversations c ON c.id = m.conversation_id
     WHERE m.conversation_id = p_conversation_id
       AND m.user_id = p_user_id
       AND m.left_at IS NULL
       AND (
         auth.current_tenant_id() IS NULL
         OR c.tenant_id = auth.current_tenant_id()
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
  SELECT p_viewer IS NOT NULL AND (
    chat.is_active_member(p_conversation_id, p_viewer)
    OR EXISTS (
      SELECT 1
        FROM chat.conversations c
       WHERE c.id = p_conversation_id
         AND c.type = 'context'
         AND internal.is_tenant_member(c.tenant_id, p_viewer)
         AND (auth.current_tenant_id() IS NULL OR c.tenant_id = auth.current_tenant_id())
    )
  );
$$;

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
           FROM platform.tenant_members a
           JOIN platform.tenant_members b
             ON b.tenant_id = a.tenant_id
          WHERE a.user_id = p_viewer
            AND b.user_id = p_target
            AND (auth.current_tenant_id() IS NULL OR a.tenant_id = auth.current_tenant_id())
       )
       OR EXISTS (
         SELECT 1
           FROM chat.conversation_members me
           JOIN chat.conversation_members other
             ON other.conversation_id = me.conversation_id
            AND other.left_at IS NULL
           JOIN chat.conversations c ON c.id = me.conversation_id
          WHERE me.user_id = p_viewer
            AND me.left_at IS NULL
            AND other.user_id = p_target
            AND (auth.current_tenant_id() IS NULL OR c.tenant_id = auth.current_tenant_id())
       )
     );
$$;

CREATE OR REPLACE FUNCTION platform.append_event(
  p_conversation_id uuid,
  p_type text,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_actor_id uuid DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_tenant uuid;
  v_seq bigint;
  v_payload jsonb;
BEGIN
  SELECT c.tenant_id INTO v_tenant
    FROM chat.conversations c
   WHERE c.id = p_conversation_id;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'conversation not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO platform.conversation_sequences (conversation_id, last_sequence)
  VALUES (p_conversation_id, 1)
  ON CONFLICT (conversation_id) DO UPDATE
    SET last_sequence = platform.conversation_sequences.last_sequence + 1
  RETURNING last_sequence INTO v_seq;

  v_payload := coalesce(p_payload, '{}'::jsonb)
    || jsonb_build_object(
         'conversation_id', p_conversation_id,
         'tenant_id', v_tenant,
         'sequence', v_seq
       );

  INSERT INTO platform.events (
    tenant_id, conversation_id, sequence, type, actor_id, payload
  ) VALUES (
    v_tenant, p_conversation_id, v_seq, p_type, p_actor_id, v_payload
  );

  PERFORM pg_notify(
    'efelant_events',
    (jsonb_build_object('type', p_type) || v_payload)::text
  );

  RETURN v_seq;
END;
$$;

CREATE OR REPLACE FUNCTION realtime.emit(p_type text, p_payload jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_conversation uuid;
BEGIN
  BEGIN
    v_conversation := (p_payload->>'conversation_id')::uuid;
  EXCEPTION WHEN others THEN
    v_conversation := NULL;
  END;

  IF v_conversation IS NOT NULL THEN
    PERFORM platform.append_event(
      v_conversation,
      p_type,
      coalesce(p_payload, '{}'::jsonb),
      auth.current_user_id()
    );
    RETURN;
  END IF;

  PERFORM pg_notify(
    'efelant_events',
    (jsonb_build_object('type', p_type) || coalesce(p_payload, '{}'::jsonb))::text
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
    RAISE EXCEPTION 'missing required field' USING ERRCODE = '22023';
  END IF;

  IF char_length(p_password) < 8 THEN
    RAISE EXCEPTION 'password must be at least 8 characters' USING ERRCODE = '22023';
  END IF;

  v_username := trim(p_username)::citext;

  INSERT INTO auth.users (username, display_name, password_hash)
  VALUES (v_username, trim(p_display_name), crypt(p_password, gen_salt('bf', 10)))
  RETURNING id INTO v_user_id;

  SELECT * INTO v_session
    FROM internal.issue_session(v_user_id, p_device_id, p_device_name, p_platform);

  PERFORM internal.bind_default_tenant(v_user_id, v_session.session_id);

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
    RAISE EXCEPTION 'username already taken' USING ERRCODE = '23505';
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
    RAISE EXCEPTION 'missing required field' USING ERRCODE = '22023';
  END IF;

  IF internal.auth_locked(p_username) THEN
    RAISE EXCEPTION 'too many failed login attempts' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_user
    FROM auth.users u
   WHERE u.username = trim(p_username)::citext;

  IF v_user.id IS NULL OR v_user.password_hash <> crypt(p_password, v_user.password_hash) THEN
    PERFORM internal.record_auth_failure(trim(p_username));
    RAISE EXCEPTION 'invalid username or password' USING ERRCODE = '28P01';
  END IF;

  DELETE FROM internal.auth_failures f WHERE f.username = trim(p_username);

  SELECT * INTO v_session
    FROM internal.issue_session(
      v_user.id,
      p_device_id,
      coalesce(p_device_name, 'device'),
      coalesce(p_platform, 'unknown')
    );

  IF v_session.session_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM auth.sessions s
     WHERE s.id = v_session.session_id AND s.tenant_id IS NOT NULL
       AND internal.is_tenant_member(s.tenant_id, v_user.id)
  ) THEN
    PERFORM auth.select_tenant((
      SELECT s.tenant_id FROM auth.sessions s WHERE s.id = v_session.session_id
    ));
  ELSE
    PERFORM internal.bind_default_tenant(v_user.id, v_session.session_id);
  END IF;

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
    RAISE EXCEPTION 'session token required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_session
    FROM auth.sessions s
   WHERE s.token_hash = internal.token_hash(p_token);

  IF v_session.id IS NULL
     OR v_session.revoked_at IS NOT NULL
     OR v_session.expires_at <= now() THEN
    RAISE EXCEPTION 'session expired or revoked' USING ERRCODE = '28000';
  END IF;

  PERFORM set_config('efelant.session_token', p_token, false);

  UPDATE auth.devices d
     SET last_seen_at = now()
   WHERE d.id = v_session.device_id;

  IF v_session.tenant_id IS NOT NULL
     AND internal.is_tenant_member(v_session.tenant_id, v_session.user_id) THEN
    PERFORM set_config('efelant.tenant_id', v_session.tenant_id::text, false);
  ELSE
    PERFORM internal.bind_default_tenant(v_session.user_id, v_session.id);
  END IF;

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
  v_tenant uuid;
  v_lo uuid;
  v_hi uuid;
  v_existing uuid;
  v_conversation_id uuid;
BEGIN
  v_me := internal.require_user_id();
  v_tenant := internal.require_tenant_id();

  IF p_other_user_id IS NULL OR p_other_user_id = v_me THEN
    RAISE EXCEPTION 'invalid peer' USING ERRCODE = '22023';
  END IF;

  IF NOT internal.is_tenant_member(v_tenant, p_other_user_id) THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
  END IF;

  v_lo := least(v_me, p_other_user_id);
  v_hi := greatest(v_me, p_other_user_id);

  SELECT dp.conversation_id INTO v_existing
    FROM chat.direct_pairs dp
   WHERE dp.tenant_id = v_tenant AND dp.user_lo = v_lo AND dp.user_hi = v_hi;

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

  INSERT INTO chat.conversations (type, title, created_by, tenant_id)
  VALUES ('direct', NULL, v_me, v_tenant)
  RETURNING id INTO v_conversation_id;

  INSERT INTO chat.conversation_members (conversation_id, user_id, role)
  VALUES
    (v_conversation_id, v_me, 'member'),
    (v_conversation_id, p_other_user_id, 'member');

  INSERT INTO chat.direct_pairs (tenant_id, user_lo, user_hi, conversation_id)
  VALUES (v_tenant, v_lo, v_hi, v_conversation_id);

  PERFORM realtime.emit(
    'conversation.updated',
    jsonb_build_object('conversation_id', v_conversation_id)
  );
  PERFORM realtime.emit(
    'member.joined',
    jsonb_build_object('conversation_id', v_conversation_id, 'user_id', v_me)
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
  v_tenant uuid;
  v_conversation_id uuid;
  v_member uuid;
BEGIN
  v_me := internal.require_user_id();
  v_tenant := internal.require_tenant_id();

  IF p_title IS NULL OR trim(p_title) = '' THEN
    RAISE EXCEPTION 'group title required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO chat.conversations (type, title, created_by, tenant_id)
  VALUES ('group', trim(p_title), v_me, v_tenant)
  RETURNING id INTO v_conversation_id;

  INSERT INTO chat.conversation_members (conversation_id, user_id, role)
  VALUES (v_conversation_id, v_me, 'admin');

  IF p_member_ids IS NOT NULL THEN
    FOREACH v_member IN ARRAY p_member_ids LOOP
      IF v_member IS NULL OR v_member = v_me THEN
        CONTINUE;
      END IF;
      IF NOT internal.is_tenant_member(v_tenant, v_member) THEN
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
  PERFORM realtime.emit(
    'member.joined',
    jsonb_build_object('conversation_id', v_conversation_id, 'user_id', v_me)
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
  v_tenant uuid;
  v_role chat.conversation_members.role%TYPE;
  v_type chat.conversations.type%TYPE;
BEGIN
  v_me := internal.require_user_id();
  v_tenant := internal.require_tenant_id();
  PERFORM chat.require_active_member(p_conversation_id, v_me);

  SELECT c.type INTO v_type
    FROM chat.conversations c
   WHERE c.id = p_conversation_id AND c.tenant_id = v_tenant;
  IF v_type IS NULL THEN
    RAISE EXCEPTION 'not a conversation member' USING ERRCODE = '42501';
  END IF;
  IF v_type <> 'group' THEN
    RAISE EXCEPTION 'can only add members to groups' USING ERRCODE = '22023';
  END IF;

  SELECT m.role INTO v_role
    FROM chat.conversation_members m
   WHERE m.conversation_id = p_conversation_id AND m.user_id = v_me AND m.left_at IS NULL;

  IF v_role <> 'admin' THEN
    RAISE EXCEPTION 'only admins can add members' USING ERRCODE = '42501';
  END IF;

  IF NOT internal.is_tenant_member(v_tenant, p_user_id) THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = 'P0002';
  END IF;

  INSERT INTO chat.conversation_members (conversation_id, user_id, role)
  VALUES (p_conversation_id, p_user_id, 'member')
  ON CONFLICT (conversation_id, user_id) DO UPDATE
    SET left_at = NULL,
        joined_at = CASE
          WHEN chat.conversation_members.left_at IS NULL
          THEN chat.conversation_members.joined_at
          ELSE now()
        END;

  PERFORM realtime.emit(
    'member.joined',
    jsonb_build_object(
      'conversation_id', p_conversation_id,
      'user_id', p_user_id
    )
  );
  RETURN true;
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
  v_tenant uuid;
  v_q text;
BEGIN
  v_me := internal.require_user_id();
  v_tenant := internal.require_tenant_id();
  v_q := trim(coalesce(p_query, ''));

  IF char_length(v_q) < 1 THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT u.id, u.username::text, u.display_name
    FROM auth.users u
    JOIN platform.tenant_members tm ON tm.user_id = u.id AND tm.tenant_id = v_tenant
   WHERE u.id <> v_me
     AND (
       u.username ILIKE ('%' || v_q || '%')
       OR u.display_name ILIKE ('%' || v_q || '%')
     )
   ORDER BY similarity(u.username::text, v_q) DESC, u.username
   LIMIT 20;
END;
$$;

CREATE OR REPLACE FUNCTION platform.ensure_context(
  p_tenant_id uuid,
  p_type text,
  p_external_id text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS platform.contexts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_ctx platform.contexts;
  v_conversation uuid;
  v_actor uuid;
BEGIN
  v_actor := auth.current_user_id();

  SELECT * INTO v_ctx
    FROM platform.contexts c
   WHERE c.tenant_id = p_tenant_id
     AND c.type = p_type
     AND c.external_id = p_external_id;

  IF v_ctx.id IS NOT NULL THEN
    IF p_metadata IS NOT NULL AND p_metadata <> '{}'::jsonb THEN
      UPDATE platform.contexts
         SET metadata = coalesce(metadata, '{}'::jsonb) || p_metadata,
             updated_at = now()
       WHERE id = v_ctx.id
       RETURNING * INTO v_ctx;
    END IF;
    RETURN v_ctx;
  END IF;

  INSERT INTO chat.conversations (type, title, created_by, tenant_id)
  VALUES (
    'context',
    left(p_type || ':' || p_external_id, 80),
    v_actor,
    p_tenant_id
  )
  RETURNING id INTO v_conversation;

  IF v_actor IS NOT NULL THEN
    INSERT INTO chat.conversation_members (conversation_id, user_id, role)
    VALUES (v_conversation, v_actor, 'member')
    ON CONFLICT DO NOTHING;
  END IF;

  INSERT INTO platform.contexts (
    tenant_id, type, external_id, metadata, conversation_id
  ) VALUES (
    p_tenant_id, p_type, p_external_id, coalesce(p_metadata, '{}'::jsonb), v_conversation
  )
  RETURNING * INTO v_ctx;

  RETURN v_ctx;
END;
$$;

CREATE OR REPLACE FUNCTION efelant.open_context(
  p_tenant_id uuid,
  p_type text,
  p_external_id text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  context_id uuid,
  conversation_id uuid,
  tenant_id uuid,
  type text,
  external_id text,
  metadata jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_ctx platform.contexts;
BEGIN
  v_me := internal.require_user_id();
  IF NOT internal.is_tenant_member(p_tenant_id, v_me) THEN
    RAISE EXCEPTION 'not a tenant member' USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('efelant.tenant_id', p_tenant_id::text, false);

  v_ctx := platform.ensure_context(p_tenant_id, p_type, p_external_id, p_metadata);

  INSERT INTO chat.conversation_members (conversation_id, user_id, role)
  VALUES (v_ctx.conversation_id, v_me, 'member')
  ON CONFLICT ON CONSTRAINT conversation_members_pkey DO UPDATE
    SET left_at = NULL;

  context_id := v_ctx.id;
  conversation_id := v_ctx.conversation_id;
  tenant_id := v_ctx.tenant_id;
  type := v_ctx.type;
  external_id := v_ctx.external_id;
  metadata := v_ctx.metadata;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION efelant.publish_event(
  p_tenant_id uuid,
  p_context_type text,
  p_external_id text,
  p_type text,
  p_message text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  event_id uuid,
  conversation_id uuid,
  sequence bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid;
  v_ctx platform.contexts;
  v_seq bigint;
  v_id uuid;
BEGIN
  v_actor := auth.current_user_id();
  IF current_user = 'efelant_app' THEN
    IF v_actor IS NULL OR NOT internal.is_tenant_member(p_tenant_id, v_actor) THEN
      RAISE EXCEPTION 'not a tenant member' USING ERRCODE = '42501';
    END IF;
  ELSIF NOT EXISTS (SELECT 1 FROM platform.tenants t WHERE t.id = p_tenant_id) THEN
    RAISE EXCEPTION 'tenant not found' USING ERRCODE = 'P0002';
  END IF;

  v_ctx := platform.ensure_context(
    p_tenant_id, p_context_type, p_external_id, coalesce(p_metadata, '{}'::jsonb)
  );

  v_seq := platform.append_event(
    v_ctx.conversation_id,
    p_type,
    jsonb_build_object(
      'message', p_message,
      'status', p_metadata->>'status',
      'metadata', coalesce(p_metadata, '{}'::jsonb),
      'context_type', p_context_type,
      'external_id', p_external_id
    ),
    v_actor
  );

  SELECT e.id INTO v_id
    FROM platform.events e
   WHERE e.conversation_id = v_ctx.conversation_id AND e.sequence = v_seq;

  event_id := v_id;
  conversation_id := v_ctx.conversation_id;
  sequence := v_seq;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION efelant.publish_status(
  p_tenant_id uuid,
  p_context_type text,
  p_external_id text,
  p_status text,
  p_message text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  event_id uuid,
  conversation_id uuid,
  sequence bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RETURN QUERY
  SELECT *
    FROM efelant.publish_event(
      p_tenant_id,
      p_context_type,
      p_external_id,
      'status.changed',
      coalesce(p_message, p_status),
      coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('status', p_status)
    );
END;
$$;

CREATE OR REPLACE FUNCTION efelant.sync_events(
  p_conversation_id uuid,
  p_after_sequence bigint DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  conversation_id uuid,
  tenant_id uuid,
  sequence bigint,
  type text,
  actor_id uuid,
  payload jsonb,
  created_at timestamptz
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
  IF NOT internal.visible_conversation(v_me, p_conversation_id) THEN
    RAISE EXCEPTION 'not a conversation member' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT e.id, e.conversation_id, e.tenant_id, e.sequence, e.type,
         e.actor_id, e.payload, e.created_at
    FROM platform.events e
   WHERE e.conversation_id = p_conversation_id
     AND e.sequence > coalesce(p_after_sequence, 0)
   ORDER BY e.sequence;
END;
$$;

CREATE OR REPLACE FUNCTION efelant.sync_context_events(
  p_tenant_id uuid,
  p_context_type text,
  p_external_id text,
  p_after_sequence bigint DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  conversation_id uuid,
  tenant_id uuid,
  sequence bigint,
  type text,
  actor_id uuid,
  payload jsonb,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_me uuid;
  v_conversation uuid;
BEGIN
  v_me := internal.require_user_id();
  IF NOT internal.is_tenant_member(p_tenant_id, v_me) THEN
    RAISE EXCEPTION 'not a tenant member' USING ERRCODE = '42501';
  END IF;

  SELECT c.conversation_id INTO v_conversation
    FROM platform.contexts c
   WHERE c.tenant_id = p_tenant_id
     AND c.type = p_context_type
     AND c.external_id = p_external_id;

  IF v_conversation IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT *
    FROM efelant.sync_events(v_conversation, p_after_sequence);
END;
$$;

CREATE OR REPLACE FUNCTION efelant.get_context(
  p_tenant_id uuid,
  p_type text,
  p_external_id text
)
RETURNS TABLE (
  context_id uuid,
  conversation_id uuid,
  tenant_id uuid,
  type text,
  external_id text,
  metadata jsonb
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
  IF NOT internal.is_tenant_member(p_tenant_id, v_me) THEN
    RAISE EXCEPTION 'not a tenant member' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id, c.conversation_id, c.tenant_id, c.type, c.external_id, c.metadata
    FROM platform.contexts c
   WHERE c.tenant_id = p_tenant_id
     AND c.type = p_type
     AND c.external_id = p_external_id;
END;
$$;

ALTER TABLE platform.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform.tenants FORCE ROW LEVEL SECURITY;
ALTER TABLE platform.tenant_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform.tenant_members FORCE ROW LEVEL SECURITY;
ALTER TABLE platform.contexts ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform.contexts FORCE ROW LEVEL SECURITY;
ALTER TABLE platform.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform.events FORCE ROW LEVEL SECURITY;
ALTER TABLE platform.conversation_sequences ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform.conversation_sequences FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenants_member ON platform.tenants;
CREATE POLICY tenants_member ON platform.tenants
  FOR SELECT
  USING (internal.is_tenant_member(id, auth.current_user_id()));

DROP POLICY IF EXISTS tenant_members_same ON platform.tenant_members;
CREATE POLICY tenant_members_same ON platform.tenant_members
  FOR SELECT
  USING (internal.is_tenant_member(tenant_id, auth.current_user_id()));

DROP POLICY IF EXISTS contexts_tenant ON platform.contexts;
CREATE POLICY contexts_tenant ON platform.contexts
  FOR SELECT
  USING (
    internal.is_tenant_member(tenant_id, auth.current_user_id())
    AND (auth.current_tenant_id() IS NULL OR tenant_id = auth.current_tenant_id())
  );

DROP POLICY IF EXISTS events_visible ON platform.events;
CREATE POLICY events_visible ON platform.events
  FOR SELECT
  USING (internal.visible_conversation(auth.current_user_id(), conversation_id));

DROP POLICY IF EXISTS sequences_visible ON platform.conversation_sequences;
CREATE POLICY sequences_visible ON platform.conversation_sequences
  FOR SELECT
  USING (internal.visible_conversation(auth.current_user_id(), conversation_id));

DROP POLICY IF EXISTS conversations_member ON chat.conversations;
CREATE POLICY conversations_member ON chat.conversations
  USING (
    internal.visible_conversation(auth.current_user_id(), id)
    AND (auth.current_tenant_id() IS NULL OR tenant_id = auth.current_tenant_id())
  );

ALTER TABLE chat.conversation_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.conversation_deliveries FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS conversation_deliveries_member ON chat.conversation_deliveries;
CREATE POLICY conversation_deliveries_member ON chat.conversation_deliveries
  USING (internal.visible_conversation(auth.current_user_id(), conversation_id));

DROP POLICY IF EXISTS presence_visible ON internal.presence;
CREATE POLICY presence_visible ON internal.presence
  USING (
    internal.visible_user(auth.current_user_id(), user_id)
    AND (
      auth.current_tenant_id() IS NULL
      OR EXISTS (
        SELECT 1 FROM platform.tenant_members tm
         WHERE tm.user_id = internal.presence.user_id
           AND tm.tenant_id = auth.current_tenant_id()
      )
    )
  );

REVOKE ALL ON ALL TABLES IN SCHEMA platform FROM PUBLIC, efelant_app;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA platform FROM PUBLIC, efelant_app;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA efelant FROM PUBLIC, efelant_app;

GRANT EXECUTE ON FUNCTION auth.current_tenant_id() TO efelant_app;
GRANT EXECUTE ON FUNCTION auth.select_tenant(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION auth.list_tenants() TO efelant_app;
GRANT EXECUTE ON FUNCTION platform.create_tenant(text, text) TO efelant_app;
GRANT EXECUTE ON FUNCTION platform.add_tenant_member(uuid, uuid, text) TO efelant_app;
GRANT EXECUTE ON FUNCTION efelant.open_context(uuid, text, text, jsonb) TO efelant_app;
GRANT EXECUTE ON FUNCTION efelant.get_context(uuid, text, text) TO efelant_app;
GRANT EXECUTE ON FUNCTION efelant.sync_events(uuid, bigint) TO efelant_app;
GRANT EXECUTE ON FUNCTION efelant.sync_context_events(uuid, text, text, bigint) TO efelant_app;
GRANT EXECUTE ON FUNCTION efelant.publish_event(uuid, text, text, text, text, jsonb) TO efelant_app;
GRANT EXECUTE ON FUNCTION efelant.publish_status(uuid, text, text, text, text, jsonb) TO efelant_app;

GRANT EXECUTE ON FUNCTION efelant.publish_event(uuid, text, text, text, text, jsonb) TO PUBLIC;
GRANT EXECUTE ON FUNCTION efelant.publish_status(uuid, text, text, text, text, jsonb) TO PUBLIC;
GRANT EXECUTE ON FUNCTION platform.create_tenant(text, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION platform.add_tenant_member(uuid, uuid, text) TO PUBLIC;

INSERT INTO internal.schema_migrations (id) VALUES ('013_platform')
ON CONFLICT (id) DO NOTHING;

RESET ROLE;
