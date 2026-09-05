#!/usr/bin/env node
// Extract REST + gRPC specs from database/init/015_api.sql into site/docs/specs/.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const sql = readFileSync(join(root, "database/init/015_api.sql"), "utf8");

function must(re, label) {
  const match = sql.match(re);
  if (!match) {
    throw new Error(`gen-api-spec: no ${label} in 015_api.sql`);
  }
  return match;
}

const proto = must(
  /SELECT \$proto\$([\s\S]*?)\$proto\$;/,
  "api.protobuf()"
)[1].trim();
const scopes = [
  ...sql.matchAll(
    /'(tenants:read|contexts:read|contexts:write|events:read|events:write|clients:write)'/g
  ),
].map((m) => m[1]);
const uniqueScopes = [...new Set(scopes)];

const messages = {};
for (const block of proto.matchAll(/message (\w+) \{([^}]*)\}/g)) {
  const fields = [];
  for (const field of block[2].matchAll(/(repeated )?(\w+) (\w+) = (\d+);/g)) {
    fields.push({
      repeated: Boolean(field[1]),
      type: field[2],
      name: field[3],
      id: Number(field[4]),
    });
  }
  messages[block[1]] = fields;
}

const rpcs = [...proto.matchAll(/rpc (\w+) \((\w+)\) returns \((\w+)\);/g)].map(
  (m) => ({
    name: m[1],
    request: m[2],
    response: m[3],
  })
);

const grpcOp = {};
const grpcFn = must(
  /CREATE OR REPLACE FUNCTION api\.handle_grpc\([\s\S]*?END;\n\$\$;/,
  "api.handle_grpc"
)[0];
for (const row of grpcFn.matchAll(/WHEN '(\w+)' THEN\s+v_op := '(\w+)';/g)) {
  grpcOp[row[2]] = row[1];
}

const pathSummaries = {};
const openapiFn = must(
  /CREATE OR REPLACE FUNCTION api\.openapi\(\)[\s\S]*?END;\n\$\$;|CREATE OR REPLACE FUNCTION api\.openapi\(\)[\s\S]*?\$\$;/,
  "api.openapi"
)[0];
for (const pathBlock of openapiFn.matchAll(
  /'(\/[^']*)',\s*jsonb_build_object\(([\s\S]*?)\)(?=,\s*\n\s+'\/|\s*\n\s*\))/g
)) {
  const path = pathBlock[1];
  pathSummaries[path] ??= {};
  for (const op of pathBlock[2].matchAll(
    /'(get|post|delete)',\s*jsonb_build_object\('summary',\s*'([^']*)'/g
  )) {
    pathSummaries[path][op[1].toUpperCase()] = {
      summary: op[2],
      public: pathBlock[2].includes("'security'"),
    };
  }
}

function templatize(raw) {
  let path = raw.replace(/^\^/, "").replace(/\$$/, "").replaceAll("\\", "");
  path = path.replace(
    /tenants\/(?:\([0-9a-fA-F-]\{36\}\)|\[0-9a-fA-F-\]\{36\})/g,
    "tenants/{tenantId}"
  );
  path = path.replace(
    /conversations\/(?:\([0-9a-fA-F-]\{36\}\)|\[0-9a-fA-F-\]\{36\})/g,
    "conversations/{conversationId}"
  );
  path = path.replace(
    /clients\/(?:\([0-9a-fA-F-]\{36\}\)|\[0-9a-fA-F-\]\{36\})/g,
    "clients/{clientId}"
  );
  path = path.replace(
    /contexts\/(?:\(\[\^\/\]\+\)|\[\^\/\]\+)/,
    "contexts/{type}"
  );
  path = path.replace(
    /contexts\/\{type\}\/(?:\(\[\^\/\]\+\)|\[\^\/\]\+)/,
    "contexts/{type}/{externalId}"
  );
  return path;
}

function pathParams(path) {
  return [...path.matchAll(/\{(\w+)\}/g)].map((m) => m[1]);
}

const TAGS = [
  { name: "Health", description: "Worker liveness. Public." },
  {
    name: "Tenants",
    description:
      "List memberships and bind the session to a tenant. Scope `tenants:read`.",
  },
  {
    name: "Contexts",
    description:
      "A context is the host record (type + external id) mapped to one conversation.",
  },
  {
    name: "Events",
    description:
      "Append-only stream on a conversation. Sync after a sequence, or publish.",
  },
  {
    name: "Clients",
    description:
      "Machine tokens (`efl_…`). Tenant owner/admin only. Scope `clients:write`.",
  },
  {
    name: "Spec",
    description: "Machine-readable OpenAPI and protobuf. Public.",
  },
];

const OP_DOCS = {
  health: {
    description:
      "Liveness for the REST worker. Returns `ok: true` and `name: efelant` when SQL can run. No bearer token.",
  },
  openapi: {
    description:
      "OpenAPI document from `api.openapi()`. The HTML on this page is generated from the same SQL and is richer (parameters, schemas, status codes).",
  },
  proto: {
    description:
      'Protobuf schema from `api.protobuf()`, wrapped as JSON `{ "proto": "…" }`. Same text as the `efelant.proto` download. Public.',
  },
  list_tenants: {
    description:
      "Tenants the caller belongs to, each with `id`, `slug`, `name`, and `role`. A human session sees every membership. An API client sees the tenant it was created for.",
  },
  select_tenant: {
    description:
      "Binds this session to `tenantId`. Later calls that take a tenant from the session use this binding. The caller must already be a member of that tenant.",
  },
  open_context: {
    description:
      "Opens or reuses the conversation for (`tenant_id`, `type`, `external_id`). Idempotent: the same triple returns the existing context. `type` and `external_id` are host-defined (for example `ticket` / `T-1`).",
  },
  get_context: {
    description:
      "Reads an existing context by tenant, type, and external id. Returns 404 if it has not been opened yet.",
  },
  sync_events: {
    description:
      "Events on a conversation with `sequence` greater than `after`. Omit `after` or pass `0` for the full stream. Ordered by sequence.",
  },
  sync_context_events: {
    description:
      "Same as conversation sync, addressed by the context triple (`tenantId`, `type`, `externalId`) instead of `conversationId`.",
  },
  publish_event: {
    description:
      "Appends a domain event to the context conversation. Send `event_type` (or `type` in the JSON body), optional `message`, and optional `metadata` object.",
  },
  publish_status: {
    description:
      "Publishes a `status.changed` event for the context. Host UIs treat `status` as the current state (for example `approved` or `rejected`).",
  },
  create_client: {
    description:
      "Creates a tenant-scoped API client. The token (`efl_…`) is in this response once and cannot be fetched again. Only tenant `owner` / `admin`. If `scopes` is omitted, the default integration scopes are applied.",
  },
  list_clients: {
    description:
      "API clients for the tenant, including `revoked_at` when revoked. Tokens are never listed.",
  },
  revoke_client: {
    description:
      "Revokes an API client. Existing `efl_…` tokens stop authenticating. Returns 404 if the id is unknown.",
  },
};

const PARAM_DOCS = {
  tenantId: "Tenant UUID.",
  type: "Host context kind (for example `ticket`). URL-decoded.",
  externalId: "Host record id (for example `T-1`). URL-decoded.",
  conversationId: "Conversation UUID from an opened context.",
  clientId: "API client UUID.",
  after: "Exclusive sequence cursor. Default `0` (full stream).",
};

const FIELD_DOCS = {
  "HealthReply.ok": "True when the worker answered.",
  "HealthReply.name": "Service name, always `efelant`.",
  tenant_id: "Tenant UUID.",
  conversation_id: "Conversation UUID.",
  context_id: "Context UUID.",
  client_id: "API client UUID.",
  external_id: "Host record id.",
  metadata_json:
    "JSON object serialized as a string in protobuf; JSON object on REST.",
  after_sequence: "Exclusive sequence cursor.",
  "Event.id": "Event UUID.",
  "Event.sequence": "Monotonic sequence in the conversation.",
  "Event.type": "Event type (`message`, `status.changed`, …).",
  "Event.actor_id": "User or API-client user that published the event.",
  "Event.payload_json": "Event payload as JSON text.",
  "Event.created_at": "RFC 3339 timestamp.",
  "PublishEventRequest.event_type":
    "Domain event type. REST also accepts `type` in the JSON body.",
  "PublishEventRequest.message": "Optional human-readable text.",
  "PublishStatusRequest.status": "New status value for the context.",
  "PublishReply.event_id": "Id of the appended event.",
  "PublishReply.sequence": "Sequence assigned to the appended event.",
  "CreateClientRequest.name": "Display name for the client.",
  "CreateClientRequest.scopes":
    "Scope strings. Default integration set if omitted.",
  "ClientCreated.token": "Bearer token, prefix `efl_`. Shown once.",
  "ClientCreated.user_id": "Service user created for this client.",
  "Client.revoked_at":
    "Set when the client was revoked; empty if still active.",
  "Tenant.role": "Membership role (`owner`, `admin`, `member`, …).",
  "Tenant.slug": "URL-safe tenant slug.",
};

const LOOKUP_OPS = new Set([
  "get_context",
  "select_tenant",
  "sync_events",
  "sync_context_events",
  "publish_event",
  "publish_status",
  "revoke_client",
  "list_clients",
  "create_client",
  "open_context",
]);

const invokeFn = must(
  /CREATE OR REPLACE FUNCTION api\.invoke\([\s\S]*?END;\n\$\$;/,
  "api.invoke"
)[0];
const opScope = {};
for (const row of invokeFn.matchAll(
  /WHEN '(\w+)' THEN\s+PERFORM api\.require_scope\('([^']+)'\);/g
)) {
  opScope[row[1]] = row[2];
}

function tagFor(path) {
  if (path.includes("/clients")) {
    return "Clients";
  }
  if (path.includes("/events") || path.endsWith("/status")) {
    return "Events";
  }
  if (path.includes("/contexts")) {
    return "Contexts";
  }
  if (path.includes("/tenants")) {
    return "Tenants";
  }
  if (path.includes("health")) {
    return "Health";
  }
  return "Spec";
}

const httpFn = must(
  /CREATE OR REPLACE FUNCTION api\.handle_http\([\s\S]*?END;\n\$\$;/,
  "api.handle_http"
)[0];
const rest = [];
const seen = new Set();

function addRest(method, path, block) {
  const invoke = block.match(/api\.invoke\(\s*'(\w+)'/);
  const key = `${method} ${path}`;
  if (seen.has(key)) {
    return;
  }
  seen.add(key);
  const op = invoke?.[1] ?? null;
  const rpc = op ? grpcOp[op] ?? null : null;
  const fromOpenapi = pathSummaries[path]?.[method];
  const opSummary = {
    health: "Liveness",
    openapi: "OpenAPI document",
    proto: "protobuf schema",
  };
  const isPublic =
    /\bv_public\s*:=\s*true\b/.test(block) || Boolean(fromOpenapi?.public);
  const scope = op ? opScope[op] ?? null : null;
  const docs = OP_DOCS[op] ?? {};
  rest.push({
    method,
    path,
    summary: fromOpenapi?.summary ?? opSummary[op] ?? rpc ?? op ?? path,
    description: docs.description ?? null,
    op,
    rpc,
    auth: !isPublic,
    scope,
    status: /status := 201/.test(block) ? 201 : 200,
    query: [...block.matchAll(/api\.query_param\(p_query,\s*'(\w+)'\)/g)].map(
      (m) => m[1]
    ),
    request: rpc
      ? messages[rpcs.find((r) => r.name === rpc)?.request] ?? []
      : [],
    response: rpc
      ? messages[rpcs.find((r) => r.name === rpc)?.response] ?? []
      : [],
    requestType: rpc ? rpcs.find((r) => r.name === rpc)?.request ?? null : null,
    responseType: rpc
      ? rpcs.find((r) => r.name === rpc)?.response ?? null
      : null,
    params: pathParams(path),
  });
}

for (const chunk of httpFn.split(/(?=ELSIF v_method|IF v_method)/)) {
  const method = chunk.match(/v_method = '(GET|POST|DELETE)'/)?.[1];
  if (!method) {
    continue;
  }
  const exact = chunk.match(/v_path = '([^']+)'/);
  const listed = chunk.match(/v_path IN \(([^)]+)\)/);
  const regex = chunk.match(/v_path ~ '([^']+)'/);
  if (exact) {
    addRest(method, exact[1], chunk);
  }
  if (listed) {
    for (const path of listed[1].matchAll(/'([^']+)'/g)) {
      addRest(method, path[1], chunk);
    }
  }
  if (regex) {
    addRest(method, templatize(regex[1]), chunk);
  }
}

for (const [path, ops] of Object.entries(pathSummaries)) {
  for (const method of Object.keys(ops)) {
    if (!seen.has(`${method} ${path}`)) {
      addRest(method, path, "");
    }
  }
}

const methodRank = { GET: 0, POST: 1, DELETE: 2 };
rest.sort(
  (a, b) =>
    a.path.localeCompare(b.path) ||
    (methodRank[a.method] ?? 9) - (methodRank[b.method] ?? 9)
);

const grpc = rpcs.map((rpc) => {
  const op =
    Object.entries(grpcOp).find(([, name]) => name === rpc.name)?.[0] ?? null;
  return {
    ...rpc,
    op,
    auth: rpc.name !== "Health",
    scope: op ? opScope[op] ?? null : null,
    description: OP_DOCS[op]?.description ?? null,
    requestFields: messages[rpc.request] ?? [],
    responseFields: messages[rpc.response] ?? [],
  };
});

function fieldDoc(message, name) {
  return FIELD_DOCS[`${message}.${name}`] ?? FIELD_DOCS[name] ?? undefined;
}

function protoToSchema(type, repeated, message, name) {
  const base = (() => {
    switch (type) {
      case "string":
        return { type: "string" };
      case "bool":
        return { type: "boolean" };
      case "int64":
        return { type: "integer", format: "int64" };
      default:
        return messages[type]
          ? { $ref: `#/components/schemas/${type}` }
          : { type: "object" };
    }
  })();
  const description = fieldDoc(message, name);
  const schema = repeated ? { type: "array", items: base } : base;
  if (description && !schema.$ref) {
    schema.description = description;
  }
  return schema;
}

function schemaFromFields(name, fields) {
  const properties = {};
  for (const field of fields) {
    properties[field.name] = protoToSchema(
      field.type,
      field.repeated,
      name,
      field.name
    );
  }
  return {
    type: "object",
    properties,
  };
}

const schemas = {};
for (const [name, fields] of Object.entries(messages)) {
  schemas[name] = schemaFromFields(name, fields);
}
schemas.Error = {
  type: "object",
  required: ["error", "code"],
  properties: {
    error: { type: "string", description: "Human-readable SQLERRM." },
    code: {
      type: "string",
      description: "PostgreSQL SQLSTATE (`28000`, `42501`, `P0002`, …).",
    },
  },
};

function errorResponse(description) {
  return {
    description,
    content: {
      "application/json": {
        schema: { $ref: "#/components/schemas/Error" },
      },
    },
  };
}

function paramSchema(name) {
  if (name === "after") {
    return { type: "integer", format: "int64", default: 0 };
  }
  if (/Id$/.test(name) && name !== "externalId") {
    return { type: "string", format: "uuid" };
  }
  return { type: "string" };
}

function operationDescription(route) {
  const parts = [];
  if (route.description) {
    parts.push(route.description);
  }
  if (!route.auth) {
    parts.push("Public. No bearer token.");
  } else if (route.scope) {
    parts.push(
      `Requires \`Authorization: Bearer <token>\` with scope \`${route.scope}\`.`
    );
  } else {
    parts.push("Requires `Authorization: Bearer <token>`.");
  }
  if (route.rpc) {
    parts.push(
      `Same SQL operation as Connect/gRPC \`POST /efelant.v1.Efelant/${route.rpc}\` on port 18081.`
    );
  }
  return parts.join("\n\n");
}

const openapiPaths = {};
for (const route of rest) {
  const item = (openapiPaths[route.path] ??= {});
  const parameters = [
    ...route.params.map((name) => ({
      name,
      in: "path",
      required: true,
      description: PARAM_DOCS[name],
      schema: paramSchema(name),
    })),
    ...route.query.map((name) => ({
      name,
      in: "query",
      required: false,
      description: PARAM_DOCS[name],
      schema: paramSchema(name),
    })),
  ];
  const successDescription =
    route.status === 201
      ? "Created. For API clients, `token` is present once."
      : route.responseType
      ? `${route.responseType} JSON.`
      : "OK.";
  const op = {
    tags: [tagFor(route.path)],
    summary: route.summary,
    description: operationDescription(route),
    operationId: route.rpc ?? route.op ?? `${route.method}_${route.path}`,
    security: route.auth ? [{ bearerAuth: [] }] : [],
    parameters,
    responses: {
      [String(route.status)]: {
        description: successDescription,
        content: route.responseType
          ? {
              "application/json": {
                schema: { $ref: `#/components/schemas/${route.responseType}` },
              },
            }
          : undefined,
      },
    },
  };
  if (
    route.method === "POST" ||
    route.params.length > 0 ||
    route.query.length > 0
  ) {
    op.responses["400"] = errorResponse(
      "Invalid JSON, UUID, or arguments. SQLSTATE `22023`, `22P02`, or `23514`."
    );
  }
  if (route.auth) {
    op.responses["401"] = errorResponse(
      "Missing or invalid bearer token. SQLSTATE `28000`."
    );
  }
  if (route.scope) {
    op.responses["403"] = errorResponse(
      `Authenticated but missing scope \`${route.scope}\`. SQLSTATE \`42501\`.`
    );
  }
  if (LOOKUP_OPS.has(route.op)) {
    op.responses["404"] = errorResponse(
      "Unknown path, context, conversation, or API client. SQLSTATE `P0002`."
    );
  }
  if (
    route.method === "POST" &&
    route.requestType &&
    route.request.length > 0
  ) {
    op.requestBody = {
      required: true,
      description: `${route.requestType} JSON. Path parameters override matching body fields when both are present.`,
      content: {
        "application/json": {
          schema: { $ref: `#/components/schemas/${route.requestType}` },
        },
      },
    };
  }
  item[route.method.toLowerCase()] = op;
}

const openapi = {
  openapi: "3.1.0",
  info: {
    title: "Efelant REST",
    version: "1.0.0",
    description:
      'Read-only spec generated from `database/init/015_api.sql` (`api.handle_http`, `api.invoke`, `api.protobuf`).\n\nErrors are JSON `{ "error", "code" }` where `code` is a PostgreSQL SQLSTATE: `28000` → 401, `42501` → 403, `P0002` → 404, `22023` / `22P02` / `23514` → 400.',
  },
  servers: [{ url: "http://localhost:18080" }],
  tags: TAGS,
  security: [{ bearerAuth: [] }],
  components: {
    securitySchemes: {
      bearerAuth: {
        type: "http",
        scheme: "bearer",
        description: "Session token or API client token (`efl_…`).",
      },
    },
    schemas,
  },
  paths: openapiPaths,
};

const catalog = {
  source: "database/init/015_api.sql",
  servers: {
    rest: "http://localhost:18080",
    grpc: "http://localhost:18081",
  },
  scopes: uniqueScopes,
  rest,
  grpc,
  messages,
  proto,
};

const outDir = join(root, "site/docs/specs");
mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, "efelant.proto"), `${proto}\n`);
writeFileSync(
  join(outDir, "openapi.json"),
  `${JSON.stringify(openapi, null, 2)}\n`
);
writeFileSync(
  join(outDir, "api.json"),
  `${JSON.stringify(catalog, null, 2)}\n`
);
console.log(
  `api-spec: ${rest.length} REST, ${grpc.length} gRPC, ${
    Object.keys(messages).length
  } messages`
);
