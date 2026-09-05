-- Third-party REST / gRPC surface. Transport is the efelant_rest and
-- efelant_grpc extensions (background workers). Authorization stays here.

CREATE SCHEMA IF NOT EXISTS api AUTHORIZATION efelant_owner;

GRANT USAGE ON SCHEMA api TO efelant_app, efelant_migrator;
GRANT CREATE ON SCHEMA api TO efelant_migrator;

SET ROLE efelant_owner;
SET search_path = pg_catalog, public;

CREATE TABLE IF NOT EXISTS platform.api_clients (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  tenant_id uuid NOT NULL REFERENCES platform.tenants (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  session_id uuid NOT NULL REFERENCES auth.sessions (id) ON DELETE CASCADE,
  name text NOT NULL,
  scopes text[] NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CONSTRAINT api_clients_name_len CHECK (char_length(name) BETWEEN 1 AND 64),
  CONSTRAINT api_clients_scopes_present CHECK (cardinality(scopes) >= 1)
);

CREATE INDEX IF NOT EXISTS api_clients_tenant_idx ON platform.api_clients (tenant_id);
CREATE UNIQUE INDEX IF NOT EXISTS api_clients_session_key ON platform.api_clients (session_id);

ALTER TABLE platform.api_clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE platform.api_clients FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS api_clients_admin ON platform.api_clients;
CREATE POLICY api_clients_admin ON platform.api_clients
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
        FROM platform.tenant_members tm
       WHERE tm.tenant_id = platform.api_clients.tenant_id
         AND tm.user_id = auth.current_user_id()
         AND tm.role IN ('owner', 'admin')
    )
  );

REVOKE ALL ON TABLE platform.api_clients FROM PUBLIC, efelant_app;

CREATE OR REPLACE FUNCTION api.known_scopes()
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ARRAY[
    'tenants:read',
    'contexts:read',
    'contexts:write',
    'events:read',
    'events:write',
    'clients:write'
  ];
$$;

CREATE OR REPLACE FUNCTION api.url_decode(p_src text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = pg_catalog, public
AS $$
DECLARE
  i int := 1;
  v_out bytea := '\x';
  v_ch text;
  v_hex text;
  v_src text;
BEGIN
  v_src := replace(p_src, '+', ' ');
  WHILE i <= char_length(v_src) LOOP
    v_ch := substr(v_src, i, 1);
    IF v_ch = '%' AND i + 2 <= char_length(v_src) THEN
      v_hex := substr(v_src, i + 1, 2);
      IF v_hex ~ '^[0-9A-Fa-f]{2}$' THEN
        v_out := v_out || decode(v_hex, 'hex');
        i := i + 3;
        CONTINUE;
      END IF;
    END IF;
    v_out := v_out || convert_to(v_ch, 'UTF8');
    i := i + 1;
  END LOOP;
  RETURN convert_from(v_out, 'UTF8');
END;
$$;

CREATE OR REPLACE FUNCTION api.query_param(p_query text, p_key text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_match text[];
BEGIN
  IF p_query IS NULL OR p_query = '' OR p_key IS NULL THEN
    RETURN NULL;
  END IF;
  v_match := regexp_match(p_query, '(?:^|&)' || p_key || '=([^&]*)');
  IF v_match IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN api.url_decode(v_match[1]);
END;
$$;

CREATE OR REPLACE FUNCTION api.bearer_token(p_headers jsonb)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT NULLIF(
    TRIM(
      regexp_replace(
        coalesce(p_headers->>'authorization', p_headers->>'Authorization', ''),
        '^[Bb]earer\s+',
        ''
      )
    ),
    ''
  );
$$;

CREATE OR REPLACE FUNCTION api.bind_bearer(p_headers jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_token text;
  v_user uuid;
BEGIN
  v_token := api.bearer_token(p_headers);
  IF v_token IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  PERFORM auth.resume_session(v_token);
  v_user := internal.require_user_id();
  RETURN v_user;
END;
$$;

CREATE OR REPLACE FUNCTION api.current_scopes()
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_session uuid;
  v_scopes text[];
BEGIN
  v_session := auth.current_session_id();
  IF v_session IS NULL THEN
    RETURN ARRAY[]::text[];
  END IF;

  SELECT c.scopes
    INTO v_scopes
    FROM platform.api_clients c
   WHERE c.session_id = v_session
     AND c.revoked_at IS NULL;

  IF v_scopes IS NULL THEN
    RETURN api.known_scopes();
  END IF;
  RETURN v_scopes;
END;
$$;

CREATE OR REPLACE FUNCTION api.require_scope(p_scope text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT (p_scope = ANY (api.current_scopes())) THEN
    RAISE EXCEPTION 'missing scope %', p_scope USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.require_tenant_admin(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT tm.role INTO v_role
    FROM platform.tenant_members tm
   WHERE tm.tenant_id = p_tenant_id
     AND tm.user_id = internal.require_user_id();
  IF v_role IS NULL OR v_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'only tenant admins can manage API clients'
      USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.create_client(
  p_tenant_id uuid,
  p_name text,
  p_scopes text[] DEFAULT NULL
)
RETURNS TABLE (
  client_id uuid,
  token text,
  user_id uuid,
  scopes text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_scopes text[];
  v_scope text;
  v_user uuid;
  v_device uuid := uuidv7();
  v_token text;
  v_hash text;
  v_session uuid;
  v_username text;
  v_id uuid;
BEGIN
  PERFORM api.require_tenant_admin(p_tenant_id);

  v_scopes := coalesce(p_scopes, ARRAY[
    'tenants:read',
    'contexts:read',
    'contexts:write',
    'events:read',
    'events:write'
  ]);

  FOREACH v_scope IN ARRAY v_scopes LOOP
    IF NOT (v_scope = ANY (api.known_scopes())) THEN
      RAISE EXCEPTION 'unknown scope %', v_scope USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_username := 'svc' || substr(replace(uuidv7()::text, '-', ''), 1, 12);
  INSERT INTO auth.users (username, display_name, password_hash)
  VALUES (
    v_username,
    trim(p_name),
    crypt(encode(gen_random_bytes(32), 'hex'), gen_salt('bf', 10))
  )
  RETURNING id INTO v_user;

  INSERT INTO platform.tenant_members (tenant_id, user_id, role)
  VALUES (p_tenant_id, v_user, 'member')
  ON CONFLICT ON CONSTRAINT tenant_members_pkey DO NOTHING;

  INSERT INTO auth.devices (id, user_id, name, platform, last_seen_at)
  VALUES (v_device, v_user, trim(p_name), 'api', now());

  v_token := 'efl_' || encode(gen_random_bytes(32), 'hex');
  v_hash := internal.token_hash(v_token);

  INSERT INTO auth.sessions (user_id, device_id, token_hash, expires_at, tenant_id)
  VALUES (v_user, v_device, v_hash, now() + interval '10 years', p_tenant_id)
  RETURNING id INTO v_session;

  INSERT INTO platform.api_clients (tenant_id, user_id, session_id, name, scopes)
  VALUES (p_tenant_id, v_user, v_session, trim(p_name), v_scopes)
  RETURNING id INTO v_id;

  client_id := v_id;
  token := v_token;
  user_id := v_user;
  scopes := v_scopes;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION api.list_clients(p_tenant_id uuid)
RETURNS TABLE (
  id uuid,
  name text,
  scopes text[],
  created_at timestamptz,
  revoked_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM api.require_tenant_admin(p_tenant_id);
  RETURN QUERY
  SELECT c.id, c.name, c.scopes, c.created_at, c.revoked_at
    FROM platform.api_clients c
   WHERE c.tenant_id = p_tenant_id
   ORDER BY c.created_at;
END;
$$;

CREATE OR REPLACE FUNCTION api.revoke_client(p_client_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_client platform.api_clients;
BEGIN
  SELECT * INTO v_client FROM platform.api_clients WHERE id = p_client_id;
  IF v_client.id IS NULL THEN
    RAISE EXCEPTION 'API client not found' USING ERRCODE = 'P0002';
  END IF;
  PERFORM api.require_tenant_admin(v_client.tenant_id);

  UPDATE platform.api_clients
     SET revoked_at = now()
   WHERE id = p_client_id
     AND revoked_at IS NULL;

  UPDATE auth.sessions
     SET revoked_at = now()
   WHERE id = v_client.session_id
     AND revoked_at IS NULL;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION api.openapi()
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT jsonb_build_object(
    'openapi', '3.1.0',
    'info', jsonb_build_object(
      'title', 'Efelant',
      'version', '1.0.0',
      'description', 'Third-party HTTP API. Served by the efelant_rest PostgreSQL extension. Same authorization as the SQL functions.'
    ),
    'servers', jsonb_build_array(
      jsonb_build_object('url', 'http://localhost:18080')
    ),
    'security', jsonb_build_array(
      jsonb_build_object('bearerAuth', '[]'::jsonb)
    ),
    'components', jsonb_build_object(
      'securitySchemes', jsonb_build_object(
        'bearerAuth', jsonb_build_object(
          'type', 'http',
          'scheme', 'bearer'
        )
      )
    ),
    'paths', jsonb_build_object(
      '/health', jsonb_build_object(
        'get', jsonb_build_object('summary', 'Liveness', 'security', '[]'::jsonb)
      ),
      '/v1/tenants', jsonb_build_object(
        'get', jsonb_build_object('summary', 'List tenants for the caller')
      ),
      '/v1/tenants/{tenantId}/select', jsonb_build_object(
        'post', jsonb_build_object('summary', 'Bind the session to a tenant')
      ),
      '/v1/contexts', jsonb_build_object(
        'post', jsonb_build_object('summary', 'Open or reuse a context conversation')
      ),
      '/v1/tenants/{tenantId}/contexts/{type}/{externalId}', jsonb_build_object(
        'get', jsonb_build_object('summary', 'Get a context')
      ),
      '/v1/tenants/{tenantId}/contexts/{type}/{externalId}/events', jsonb_build_object(
        'get', jsonb_build_object('summary', 'Sync context events after a sequence'),
        'post', jsonb_build_object('summary', 'Publish a domain event')
      ),
      '/v1/tenants/{tenantId}/contexts/{type}/{externalId}/status', jsonb_build_object(
        'post', jsonb_build_object('summary', 'Publish a status.changed event')
      ),
      '/v1/conversations/{conversationId}/events', jsonb_build_object(
        'get', jsonb_build_object('summary', 'Sync conversation events after a sequence')
      ),
      '/v1/tenants/{tenantId}/clients', jsonb_build_object(
        'get', jsonb_build_object('summary', 'List API clients'),
        'post', jsonb_build_object('summary', 'Create an API client (token shown once)')
      ),
      '/v1/clients/{clientId}', jsonb_build_object(
        'delete', jsonb_build_object('summary', 'Revoke an API client')
      )
    )
  );
$$;

CREATE OR REPLACE FUNCTION api.protobuf()
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT $proto$syntax = "proto3";
package efelant.v1;

service Efelant {
  rpc Health (HealthRequest) returns (HealthReply);
  rpc ListTenants (Empty) returns (TenantList);
  rpc SelectTenant (SelectTenantRequest) returns (SelectTenantReply);
  rpc OpenContext (OpenContextRequest) returns (Context);
  rpc GetContext (GetContextRequest) returns (Context);
  rpc SyncEvents (SyncEventsRequest) returns (EventList);
  rpc SyncContextEvents (SyncContextEventsRequest) returns (EventList);
  rpc PublishEvent (PublishEventRequest) returns (PublishReply);
  rpc PublishStatus (PublishStatusRequest) returns (PublishReply);
  rpc CreateClient (CreateClientRequest) returns (ClientCreated);
  rpc ListClients (ListClientsRequest) returns (ClientList);
  rpc RevokeClient (RevokeClientRequest) returns (Empty);
}

message Empty {}
message HealthRequest {}
message HealthReply { bool ok = 1; string name = 2; }
message Tenant { string id = 1; string slug = 2; string name = 3; string role = 4; }
message TenantList { repeated Tenant tenants = 1; }
message SelectTenantRequest { string tenant_id = 1; }
message SelectTenantReply { string tenant_id = 1; }
message OpenContextRequest {
  string tenant_id = 1;
  string type = 2;
  string external_id = 3;
  string metadata_json = 4;
}
message GetContextRequest {
  string tenant_id = 1;
  string type = 2;
  string external_id = 3;
}
message Context {
  string context_id = 1;
  string conversation_id = 2;
  string tenant_id = 3;
  string type = 4;
  string external_id = 5;
  string metadata_json = 6;
}
message SyncEventsRequest { string conversation_id = 1; int64 after_sequence = 2; }
message SyncContextEventsRequest {
  string tenant_id = 1;
  string type = 2;
  string external_id = 3;
  int64 after_sequence = 4;
}
message Event {
  string id = 1;
  string conversation_id = 2;
  string tenant_id = 3;
  int64 sequence = 4;
  string type = 5;
  string actor_id = 6;
  string payload_json = 7;
  string created_at = 8;
}
message EventList { repeated Event events = 1; }
message PublishEventRequest {
  string tenant_id = 1;
  string type = 2;
  string external_id = 3;
  string event_type = 4;
  string message = 5;
  string metadata_json = 6;
}
message PublishStatusRequest {
  string tenant_id = 1;
  string type = 2;
  string external_id = 3;
  string status = 4;
  string message = 5;
  string metadata_json = 6;
}
message PublishReply {
  string event_id = 1;
  string conversation_id = 2;
  int64 sequence = 3;
}
message CreateClientRequest {
  string tenant_id = 1;
  string name = 2;
  repeated string scopes = 3;
}
message ClientCreated {
  string client_id = 1;
  string token = 2;
  string user_id = 3;
  repeated string scopes = 4;
}
message ListClientsRequest { string tenant_id = 1; }
message Client {
  string id = 1;
  string name = 2;
  repeated string scopes = 3;
  string created_at = 4;
  string revoked_at = 5;
}
message ClientList { repeated Client clients = 1; }
message RevokeClientRequest { string client_id = 1; }
$proto$;
$$;

CREATE OR REPLACE FUNCTION api.invoke(p_op text, p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_args jsonb := coalesce(p_args, '{}'::jsonb);
  v_meta jsonb;
  v_scopes text[];
BEGIN
  CASE p_op
    WHEN 'health' THEN
      RETURN jsonb_build_object('ok', true, 'name', 'efelant');

    WHEN 'openapi' THEN
      RETURN api.openapi();

    WHEN 'proto' THEN
      RETURN jsonb_build_object('proto', api.protobuf());

    WHEN 'list_tenants' THEN
      PERFORM api.require_scope('tenants:read');
      RETURN jsonb_build_object(
        'tenants',
        coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM auth.list_tenants() t), '[]'::jsonb)
      );

    WHEN 'select_tenant' THEN
      PERFORM api.require_scope('tenants:read');
      RETURN jsonb_build_object(
        'tenant_id',
        auth.select_tenant((v_args->>'tenant_id')::uuid)
      );

    WHEN 'open_context' THEN
      PERFORM api.require_scope('contexts:write');
      v_meta := coalesce(v_args->'metadata', '{}'::jsonb);
      IF jsonb_typeof(v_meta) <> 'object' THEN
        v_meta := '{}'::jsonb;
      END IF;
      RETURN (
        SELECT to_jsonb(t)
          FROM efelant.open_context(
            (v_args->>'tenant_id')::uuid,
            v_args->>'type',
            v_args->>'external_id',
            v_meta
          ) t
      );

    WHEN 'get_context' THEN
      PERFORM api.require_scope('contexts:read');
      RETURN coalesce(
        (
          SELECT to_jsonb(t)
            FROM efelant.get_context(
              (v_args->>'tenant_id')::uuid,
              v_args->>'type',
              v_args->>'external_id'
            ) t
        ),
        NULL
      );

    WHEN 'sync_events' THEN
      PERFORM api.require_scope('events:read');
      RETURN jsonb_build_object(
        'events',
        coalesce(
          (
            SELECT jsonb_agg(to_jsonb(e) ORDER BY e.sequence)
              FROM efelant.sync_events(
                (v_args->>'conversation_id')::uuid,
                coalesce((v_args->>'after_sequence')::bigint, 0)
              ) e
          ),
          '[]'::jsonb
        )
      );

    WHEN 'sync_context_events' THEN
      PERFORM api.require_scope('events:read');
      RETURN jsonb_build_object(
        'events',
        coalesce(
          (
            SELECT jsonb_agg(to_jsonb(e) ORDER BY e.sequence)
              FROM efelant.sync_context_events(
                (v_args->>'tenant_id')::uuid,
                v_args->>'type',
                v_args->>'external_id',
                coalesce((v_args->>'after_sequence')::bigint, 0)
              ) e
          ),
          '[]'::jsonb
        )
      );

    WHEN 'publish_event' THEN
      PERFORM api.require_scope('events:write');
      v_meta := coalesce(v_args->'metadata', '{}'::jsonb);
      IF jsonb_typeof(v_meta) <> 'object' THEN
        v_meta := '{}'::jsonb;
      END IF;
      RETURN (
        SELECT to_jsonb(t)
          FROM efelant.publish_event(
            (v_args->>'tenant_id')::uuid,
            v_args->>'type',
            v_args->>'external_id',
            v_args->>'event_type',
            v_args->>'message',
            v_meta
          ) t
      );

    WHEN 'publish_status' THEN
      PERFORM api.require_scope('events:write');
      v_meta := coalesce(v_args->'metadata', '{}'::jsonb);
      IF jsonb_typeof(v_meta) <> 'object' THEN
        v_meta := '{}'::jsonb;
      END IF;
      RETURN (
        SELECT to_jsonb(t)
          FROM efelant.publish_status(
            (v_args->>'tenant_id')::uuid,
            v_args->>'type',
            v_args->>'external_id',
            v_args->>'status',
            v_args->>'message',
            v_meta
          ) t
      );

    WHEN 'create_client' THEN
      PERFORM api.require_scope('clients:write');
      IF jsonb_typeof(v_args->'scopes') = 'array' THEN
        SELECT array_agg(x)
          INTO v_scopes
          FROM jsonb_array_elements_text(v_args->'scopes') x;
      END IF;
      RETURN (
        SELECT to_jsonb(t)
          FROM api.create_client(
            (v_args->>'tenant_id')::uuid,
            v_args->>'name',
            v_scopes
          ) t
      );

    WHEN 'list_clients' THEN
      PERFORM api.require_scope('clients:write');
      RETURN jsonb_build_object(
        'clients',
        coalesce(
          (
            SELECT jsonb_agg(to_jsonb(c))
              FROM api.list_clients((v_args->>'tenant_id')::uuid) c
          ),
          '[]'::jsonb
        )
      );

    WHEN 'revoke_client' THEN
      PERFORM api.require_scope('clients:write');
      RETURN jsonb_build_object(
        'ok',
        api.revoke_client((v_args->>'client_id')::uuid)
      );

    ELSE
      RAISE EXCEPTION 'unknown operation %', p_op USING ERRCODE = 'P0002';
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION api.status_for_sqlstate(p_state text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_state
    WHEN '28000' THEN 401
    WHEN '42501' THEN 403
    WHEN 'P0002' THEN 404
    WHEN '22023' THEN 400
    WHEN '22P02' THEN 400
    WHEN '23514' THEN 400
    ELSE 400
  END;
$$;

CREATE OR REPLACE FUNCTION api.grpc_code(p_status integer)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_status
    WHEN 200 THEN 'ok'
    WHEN 400 THEN 'invalid_argument'
    WHEN 401 THEN 'unauthenticated'
    WHEN 403 THEN 'permission_denied'
    WHEN 404 THEN 'not_found'
    ELSE 'internal'
  END;
$$;

CREATE OR REPLACE FUNCTION api.handle_http(
  p_method text,
  p_path text,
  p_query text,
  p_headers jsonb,
  p_body text
)
RETURNS TABLE (
  status integer,
  headers jsonb,
  body jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_method text := upper(trim(p_method));
  v_path text;
  v_headers jsonb := coalesce(p_headers, '{}'::jsonb);
  v_body jsonb := '{}'::jsonb;
  v_args jsonb;
  v_m text[];
  v_after bigint;
  v_result jsonb;
  v_public boolean := false;
BEGIN
  v_path := regexp_replace(coalesce(p_path, '/'), '/+$', '');
  IF v_path = '' THEN
    v_path := '/';
  END IF;

  IF p_body IS NOT NULL AND length(trim(p_body)) > 0 THEN
    BEGIN
      v_body := p_body::jsonb;
    EXCEPTION WHEN invalid_text_representation THEN
      status := 400;
      headers := jsonb_build_object('content-type', 'application/json');
      body := jsonb_build_object('error', 'invalid json');
      RETURN NEXT;
      RETURN;
    END;
  END IF;

  IF v_method = 'OPTIONS' THEN
    status := 204;
    headers := jsonb_build_object(
      'access-control-allow-origin', '*',
      'access-control-allow-headers', 'authorization, content-type',
      'access-control-allow-methods', 'GET, POST, DELETE, OPTIONS'
    );
    body := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  IF v_method = 'GET' AND v_path IN ('/health', '/v1/health') THEN
    v_public := true;
    v_result := api.invoke('health', '{}'::jsonb);
    status := 200;
  ELSIF v_method = 'GET' AND v_path = '/v1/openapi.json' THEN
    v_public := true;
    v_result := api.invoke('openapi', '{}'::jsonb);
    status := 200;
  ELSIF v_method = 'GET' AND v_path IN ('/v1/efelant.proto', '/efelant.v1.Efelant.proto') THEN
    v_public := true;
    v_result := api.invoke('proto', '{}'::jsonb);
    status := 200;
  ELSE
    PERFORM api.bind_bearer(v_headers);

    IF v_method = 'GET' AND v_path = '/v1/tenants' THEN
      v_result := api.invoke('list_tenants', '{}'::jsonb);
      status := 200;
    ELSIF v_method = 'POST' AND v_path ~ '^/v1/tenants/[0-9a-fA-F-]{36}/select$' THEN
      v_m := regexp_match(v_path, '^/v1/tenants/([0-9a-fA-F-]{36})/select$');
      v_result := api.invoke(
        'select_tenant',
        jsonb_build_object('tenant_id', v_m[1])
      );
      status := 200;
    ELSIF v_method = 'POST' AND v_path = '/v1/contexts' THEN
      v_result := api.invoke('open_context', v_body);
      status := 200;
    ELSIF v_method = 'GET' AND v_path ~ '^/v1/tenants/[0-9a-fA-F-]{36}/contexts/[^/]+/[^/]+/events$' THEN
      v_m := regexp_match(
        v_path,
        '^/v1/tenants/([0-9a-fA-F-]{36})/contexts/([^/]+)/([^/]+)/events$'
      );
      v_after := coalesce(api.query_param(p_query, 'after')::bigint, 0);
      v_result := api.invoke(
        'sync_context_events',
        jsonb_build_object(
          'tenant_id', v_m[1],
          'type', api.url_decode(v_m[2]),
          'external_id', api.url_decode(v_m[3]),
          'after_sequence', v_after
        )
      );
      status := 200;
    ELSIF v_method = 'POST' AND v_path ~ '^/v1/tenants/[0-9a-fA-F-]{36}/contexts/[^/]+/[^/]+/events$' THEN
      v_m := regexp_match(
        v_path,
        '^/v1/tenants/([0-9a-fA-F-]{36})/contexts/([^/]+)/([^/]+)/events$'
      );
      v_args := v_body || jsonb_build_object(
        'tenant_id', v_m[1],
        'type', api.url_decode(v_m[2]),
        'external_id', api.url_decode(v_m[3]),
        'event_type', coalesce(v_body->>'type', v_body->>'event_type')
      );
      v_result := api.invoke('publish_event', v_args);
      status := 200;
    ELSIF v_method = 'POST' AND v_path ~ '^/v1/tenants/[0-9a-fA-F-]{36}/contexts/[^/]+/[^/]+/status$' THEN
      v_m := regexp_match(
        v_path,
        '^/v1/tenants/([0-9a-fA-F-]{36})/contexts/([^/]+)/([^/]+)/status$'
      );
      v_args := v_body || jsonb_build_object(
        'tenant_id', v_m[1],
        'type', api.url_decode(v_m[2]),
        'external_id', api.url_decode(v_m[3])
      );
      v_result := api.invoke('publish_status', v_args);
      status := 200;
    ELSIF v_method = 'GET' AND v_path ~ '^/v1/tenants/[0-9a-fA-F-]{36}/contexts/[^/]+/[^/]+$' THEN
      v_m := regexp_match(
        v_path,
        '^/v1/tenants/([0-9a-fA-F-]{36})/contexts/([^/]+)/([^/]+)$'
      );
      v_result := api.invoke(
        'get_context',
        jsonb_build_object(
          'tenant_id', v_m[1],
          'type', api.url_decode(v_m[2]),
          'external_id', api.url_decode(v_m[3])
        )
      );
      IF v_result IS NULL THEN
        RAISE EXCEPTION 'context not found' USING ERRCODE = 'P0002';
      END IF;
      status := 200;
    ELSIF v_method = 'GET' AND v_path ~ '^/v1/conversations/[0-9a-fA-F-]{36}/events$' THEN
      v_m := regexp_match(v_path, '^/v1/conversations/([0-9a-fA-F-]{36})/events$');
      v_after := coalesce(api.query_param(p_query, 'after')::bigint, 0);
      v_result := api.invoke(
        'sync_events',
        jsonb_build_object(
          'conversation_id', v_m[1],
          'after_sequence', v_after
        )
      );
      status := 200;
    ELSIF v_method = 'GET' AND v_path ~ '^/v1/tenants/[0-9a-fA-F-]{36}/clients$' THEN
      v_m := regexp_match(v_path, '^/v1/tenants/([0-9a-fA-F-]{36})/clients$');
      v_result := api.invoke(
        'list_clients',
        jsonb_build_object('tenant_id', v_m[1])
      );
      status := 200;
    ELSIF v_method = 'POST' AND v_path ~ '^/v1/tenants/[0-9a-fA-F-]{36}/clients$' THEN
      v_m := regexp_match(v_path, '^/v1/tenants/([0-9a-fA-F-]{36})/clients$');
      v_result := api.invoke(
        'create_client',
        coalesce(v_body, '{}'::jsonb) || jsonb_build_object('tenant_id', v_m[1])
      );
      status := 201;
    ELSIF v_method = 'DELETE' AND v_path ~ '^/v1/clients/[0-9a-fA-F-]{36}$' THEN
      v_m := regexp_match(v_path, '^/v1/clients/([0-9a-fA-F-]{36})$');
      v_result := api.invoke(
        'revoke_client',
        jsonb_build_object('client_id', v_m[1])
      );
      status := 200;
    ELSE
      RAISE EXCEPTION 'not found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  headers := jsonb_build_object(
    'content-type', 'application/json',
    'access-control-allow-origin', '*'
  );
  body := v_result;
  RETURN NEXT;
  RETURN;
EXCEPTION WHEN OTHERS THEN
  status := api.status_for_sqlstate(SQLSTATE);
  headers := jsonb_build_object(
    'content-type', 'application/json',
    'access-control-allow-origin', '*'
  );
  body := jsonb_build_object('error', SQLERRM, 'code', SQLSTATE);
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION api.handle_grpc(
  p_service text,
  p_method text,
  p_metadata jsonb,
  p_message jsonb
)
RETURNS TABLE (
  status integer,
  headers jsonb,
  body jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_service text := coalesce(nullif(p_service, ''), 'efelant.v1.Efelant');
  v_method text := coalesce(p_method, '');
  v_meta jsonb := coalesce(p_metadata, '{}'::jsonb);
  v_msg jsonb := coalesce(p_message, '{}'::jsonb);
  v_args jsonb;
  v_result jsonb;
  v_op text;
  v_public boolean := false;
BEGIN
  IF v_service NOT IN ('efelant.v1.Efelant', 'Efelant') THEN
    RAISE EXCEPTION 'unknown service %', v_service USING ERRCODE = 'P0002';
  END IF;

  CASE v_method
    WHEN 'Health' THEN
      v_op := 'health';
      v_public := true;
    WHEN 'ListTenants' THEN
      v_op := 'list_tenants';
    WHEN 'SelectTenant' THEN
      v_op := 'select_tenant';
    WHEN 'OpenContext' THEN
      v_op := 'open_context';
    WHEN 'GetContext' THEN
      v_op := 'get_context';
    WHEN 'SyncEvents' THEN
      v_op := 'sync_events';
    WHEN 'SyncContextEvents' THEN
      v_op := 'sync_context_events';
    WHEN 'PublishEvent' THEN
      v_op := 'publish_event';
      v_args := v_msg || jsonb_build_object(
        'event_type', coalesce(v_msg->>'event_type', v_msg->>'type'),
        'type', coalesce(v_msg->>'type', v_msg->>'context_type')
      );
    WHEN 'PublishStatus' THEN
      v_op := 'publish_status';
    WHEN 'CreateClient' THEN
      v_op := 'create_client';
    WHEN 'ListClients' THEN
      v_op := 'list_clients';
    WHEN 'RevokeClient' THEN
      v_op := 'revoke_client';
    ELSE
      RAISE EXCEPTION 'unknown method %', v_method USING ERRCODE = 'P0002';
  END CASE;

  IF NOT v_public THEN
    PERFORM api.bind_bearer(v_meta);
  END IF;

  IF v_args IS NULL THEN
    v_args := v_msg;
    IF v_args ? 'metadata_json' AND NOT v_args ? 'metadata' THEN
      BEGIN
        v_args := v_args || jsonb_build_object(
          'metadata', (v_args->>'metadata_json')::jsonb
        );
      EXCEPTION WHEN OTHERS THEN
        v_args := v_args || jsonb_build_object('metadata', '{}'::jsonb);
      END;
    END IF;
  END IF;

  v_result := api.invoke(v_op, v_args);
  IF v_op = 'get_context' AND v_result IS NULL THEN
    RAISE EXCEPTION 'context not found' USING ERRCODE = 'P0002';
  END IF;

  status := 200;
  headers := jsonb_build_object(
    'content-type', 'application/json',
    'grpc-status', '0'
  );
  body := v_result;
  RETURN NEXT;
  RETURN;
EXCEPTION WHEN OTHERS THEN
  status := api.status_for_sqlstate(SQLSTATE);
  headers := jsonb_build_object(
    'content-type', 'application/json',
    'grpc-status', CASE WHEN status = 401 THEN '16'
                        WHEN status = 403 THEN '7'
                        WHEN status = 404 THEN '5'
                        WHEN status = 400 THEN '3'
                        ELSE '13' END
  );
  body := jsonb_build_object(
    'code', api.grpc_code(status),
    'message', SQLERRM
  );
  RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION api.known_scopes() TO efelant_app;
GRANT EXECUTE ON FUNCTION api.url_decode(text) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.query_param(text, text) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.bearer_token(jsonb) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.bind_bearer(jsonb) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.current_scopes() TO efelant_app;
GRANT EXECUTE ON FUNCTION api.require_scope(text) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.require_tenant_admin(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.create_client(uuid, text, text[]) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.list_clients(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.revoke_client(uuid) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.openapi() TO efelant_app;
GRANT EXECUTE ON FUNCTION api.protobuf() TO efelant_app;
GRANT EXECUTE ON FUNCTION api.invoke(text, jsonb) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.handle_http(text, text, text, jsonb, text) TO efelant_app;
GRANT EXECUTE ON FUNCTION api.handle_grpc(text, text, jsonb, jsonb) TO efelant_app;

INSERT INTO internal.schema_migrations (id) VALUES ('015_api')
ON CONFLICT (id) DO NOTHING;

RESET ROLE;

DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS efelant_rest;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'efelant_rest extension not loaded: %', SQLERRM;
END
$$;

DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS efelant_grpc;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'efelant_grpc extension not loaded: %', SQLERRM;
END
$$;
