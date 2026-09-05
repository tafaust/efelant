// src/errors.ts
var EfelantError = class extends Error {
  code;
  constructor(message, code = "EFELANT") {
    super(message);
    this.name = "EfelantError";
    this.code = code;
  }
};
var EfelantAuthError = class extends EfelantError {
  constructor(message, code = "28000") {
    super(message, code);
    this.name = "EfelantAuthError";
  }
};
var EfelantForbiddenError = class extends EfelantError {
  constructor(message, code = "42501") {
    super(message, code);
    this.name = "EfelantForbiddenError";
  }
};
function errorFromSql(message, code) {
  const text = message.toLowerCase();
  if (text.includes("not authenticated") || text.includes("session") || code === "28000") {
    return new EfelantAuthError(message, code);
  }
  if (text.includes("member") || text.includes("tenant") || code === "42501") {
    return new EfelantForbiddenError(message, code);
  }
  return new EfelantError(message, code ?? "EFELANT");
}

// src/transport.ts
async function sql(transport, text, params = []) {
  try {
    const result = await transport.query(text, params);
    return result.rows;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    throw errorFromSql(message);
  }
}
function createGatewayTransport(url) {
  let socket;
  let nextId = 1;
  const pending = /* @__PURE__ */ new Map();
  function ensure() {
    if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
      return socket;
    }
    socket = new WebSocket(url);
    socket.addEventListener("message", (event) => {
      const data = JSON.parse(String(event.data));
      if (data.id == null) {
        return;
      }
      const waiter = pending.get(data.id);
      if (!waiter) {
        return;
      }
      pending.delete(data.id);
      if (data.error) {
        waiter.reject(new Error(data.error));
        return;
      }
      waiter.resolve({ rows: data.rows ?? [] });
    });
    return socket;
  }
  return {
    async query(sqlText, params = []) {
      const ws = ensure();
      if (ws.readyState !== WebSocket.OPEN) {
        await new Promise((resolve, reject) => {
          ws.addEventListener("open", () => resolve(), { once: true });
          ws.addEventListener("error", () => reject(new Error("gateway socket failed")), {
            once: true
          });
        });
      }
      const id = nextId++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        ws.send(JSON.stringify({ id, sql: sqlText, params }));
      });
    },
    async close() {
      socket?.close();
    }
  };
}

// src/client.ts
var EfelantClient = class {
  constructor(options) {
    this.options = options;
  }
  lastSequence = /* @__PURE__ */ new Map();
  get transport() {
    return this.options.transport;
  }
  async login(username, password, deviceId, deviceName = "web", platform = "web") {
    const [row] = await sql(
      this.transport,
      "SELECT * FROM auth.login($1::text,$2::text,$3::uuid,$4::text,$5::text)",
      [username, password, deviceId, deviceName, platform]
    );
    return row;
  }
  async resume(token) {
    const [row] = await sql(
      this.transport,
      "SELECT * FROM auth.resume_session($1::text)",
      [token]
    );
    return row;
  }
  async logout() {
    await sql(this.transport, "SELECT auth.logout()");
  }
  async listTenants() {
    return sql(this.transport, "SELECT id, slug, name, role FROM auth.list_tenants()");
  }
  async selectTenant(tenantId) {
    const [row] = await sql(
      this.transport,
      "SELECT auth.select_tenant($1::uuid)",
      [tenantId]
    );
    return row.select_tenant;
  }
  async currentTenantId() {
    const [row] = await sql(
      this.transport,
      "SELECT auth.current_tenant_id()"
    );
    return row.current_tenant_id;
  }
  async openContext(tenantId, context) {
    const [row] = await sql(
      this.transport,
      "SELECT * FROM efelant.open_context($1::uuid,$2::text,$3::text,$4::jsonb)",
      [tenantId, context.type, context.externalId, JSON.stringify(context.metadata ?? {})]
    );
    return {
      contextId: String(row.context_id),
      conversationId: String(row.conversation_id),
      tenantId: String(row.tenant_id),
      type: String(row.type),
      externalId: String(row.external_id),
      metadata: row.metadata ?? {}
    };
  }
  async syncEvents(cursor) {
    const rows = await sql(
      this.transport,
      "SELECT * FROM efelant.sync_events($1::uuid,$2::bigint)",
      [cursor.conversationId, cursor.lastSequence]
    );
    const events = rows.map(asEvent);
    const last = events.at(-1);
    if (last) {
      this.lastSequence.set(cursor.conversationId, last.sequence);
    }
    return events;
  }
  async syncContext(tenantId, context, lastSequence = 0) {
    const rows = await sql(
      this.transport,
      "SELECT * FROM efelant.sync_context_events($1::uuid,$2::text,$3::text,$4::bigint)",
      [tenantId, context.type, context.externalId, lastSequence]
    );
    return rows.map(asEvent);
  }
  cursor(conversationId) {
    return {
      conversationId,
      lastSequence: this.lastSequence.get(conversationId) ?? 0
    };
  }
  async getConversations() {
    return sql(this.transport, "SELECT * FROM chat.get_conversations()");
  }
  async getMessages(conversationId) {
    return sql(this.transport, "SELECT * FROM chat.get_messages($1::uuid)", [conversationId]);
  }
  async sendMessage(conversationId, clientId, content) {
    await sql(
      this.transport,
      "SELECT * FROM chat.send_message($1::uuid,$2::uuid,'text',$3::text,NULL,NULL)",
      [conversationId, clientId, content]
    );
  }
  async reconnect(token) {
    return this.resume(token);
  }
};
function asEvent(row) {
  return {
    id: String(row.id),
    conversationId: String(row.conversation_id),
    tenantId: String(row.tenant_id),
    sequence: Number(row.sequence),
    type: String(row.type),
    actorId: row.actor_id == null ? null : String(row.actor_id),
    payload: row.payload ?? {},
    createdAt: String(row.created_at)
  };
}

// src/memory.ts
var FN = /(auth|chat|efelant)\.[a-z_]+/i;
var TENANT = "00000000-0000-4000-8000-000000000001";
var ALICE = "00000000-0000-4000-8000-000000000002";
var BOB = "00000000-0000-4000-8000-000000000003";
var CHARLIE = "00000000-0000-4000-8000-000000000004";
var CONV_BOB = "00000000-0000-4000-8000-000000000010";
var CONV_CHARLIE = "00000000-0000-4000-8000-000000000011";
var CONV_AR = "00000000-0000-4000-8000-000000000012";
var CTX_AR = "00000000-0000-4000-8000-000000000020";
function iso(offsetSec = 0) {
  return new Date(Date.parse("2026-09-05T10:00:00Z") + offsetSec * 1e3).toISOString();
}
function newId(store) {
  store.next += 1;
  return `00000000-0000-4000-8000-${String(store.next).padStart(12, "0")}`;
}
function requireUser(store, conn) {
  if (!conn.session) {
    throw new Error("not authenticated");
  }
  const user = store.users.find((item) => item.id === conn.session?.userId);
  if (!user) {
    throw new Error("not authenticated");
  }
  return user;
}
function seedStore() {
  const store = {
    users: [
      { id: ALICE, username: "alice", displayName: "Alice", password: "password123", online: true },
      { id: BOB, username: "bob", displayName: "Bob", password: "password123", online: true },
      { id: CHARLIE, username: "charlie", displayName: "Charlie", password: "password123", online: false }
    ],
    conversations: [
      { id: CONV_BOB, type: "direct", title: "Bob", peerUserId: BOB },
      { id: CONV_CHARLIE, type: "direct", title: "Charlie", peerUserId: CHARLIE },
      { id: CONV_AR, type: "group", title: "AR-123", peerUserId: null }
    ],
    members: /* @__PURE__ */ new Map([
      [CONV_BOB, /* @__PURE__ */ new Set([ALICE, BOB])],
      [CONV_CHARLIE, /* @__PURE__ */ new Set([ALICE, CHARLIE])],
      [CONV_AR, /* @__PURE__ */ new Set([ALICE, BOB])]
    ]),
    messages: [],
    events: [],
    sequences: /* @__PURE__ */ new Map(),
    next: 100
  };
  addMessage(store, CONV_BOB, BOB, "Can you look at AR-123?", iso(0));
  addMessage(store, CONV_BOB, ALICE, "In the same transaction as the approve.", iso(30));
  addEvent(store, CONV_AR, "status.changed", BOB, { status: "approved", message: "approved the request" }, iso(60));
  addMessage(store, CONV_AR, BOB, "approved the request", iso(60));
  return store;
}
function addMessage(store, conversationId, senderId, content, createdAt) {
  const message = {
    id: newId(store),
    conversationId,
    senderId,
    clientId: newId(store),
    type: "text",
    content,
    createdAt
  };
  store.messages.push(message);
  addEvent(
    store,
    conversationId,
    "message.created",
    senderId,
    { content, message_id: message.id, sender_id: senderId },
    createdAt
  );
  return message;
}
function addEvent(store, conversationId, type, actorId, payload, createdAt) {
  const sequence = (store.sequences.get(conversationId) ?? 0) + 1;
  store.sequences.set(conversationId, sequence);
  const event = {
    id: newId(store),
    conversationId,
    tenantId: TENANT,
    sequence,
    type,
    actorId,
    payload,
    createdAt
  };
  store.events.push(event);
  return event;
}
function userById(store, id) {
  return store.users.find((item) => item.id === id);
}
function login(store, conn, params) {
  const username = String(params[0] ?? "").trim().toLowerCase();
  const password = String(params[1] ?? "");
  const deviceId = String(params[2] ?? newId(store));
  const user = store.users.find((item) => item.username === username);
  if (!user || user.password !== password) {
    throw new Error("invalid username or password");
  }
  const token = `mem_${user.id}`;
  conn.session = { userId: user.id, token, deviceId };
  return {
    rows: [
      {
        user_id: user.id,
        username: user.username,
        display_name: user.displayName,
        session_id: newId(store),
        session_token: token,
        device_id: deviceId,
        expires_at: iso(86400)
      }
    ]
  };
}
function resume(store, conn, params) {
  const token = String(params[0] ?? "");
  const userId = token.startsWith("mem_") ? token.slice(4) : "";
  const user = store.users.find((item) => item.id === userId);
  if (!user) {
    throw new Error("session not found");
  }
  conn.session = { userId: user.id, token, deviceId: conn.session?.deviceId ?? newId(store) };
  return {
    rows: [
      {
        user_id: user.id,
        username: user.username,
        display_name: user.displayName,
        session_id: newId(store),
        session_token: token,
        device_id: conn.session.deviceId,
        expires_at: iso(86400)
      }
    ]
  };
}
function listTenants() {
  return {
    rows: [{ id: TENANT, slug: "standalone", name: "standalone", role: "owner" }]
  };
}
function getConversations(store, conn) {
  const me = requireUser(store, conn);
  return {
    rows: store.conversations.filter((conversation) => store.members.get(conversation.id)?.has(me.id)).map((conversation) => {
      const members = [...store.members.get(conversation.id) ?? []];
      const peerId = conversation.type === "direct" ? members.find((id) => id !== me.id) ?? conversation.peerUserId : conversation.peerUserId;
      const peer = peerId ? userById(store, peerId) : void 0;
      const last = [...store.messages].reverse().find((message) => message.conversationId === conversation.id);
      return {
        id: conversation.id,
        type: conversation.type,
        title: conversation.type === "direct" ? peer?.displayName ?? conversation.title : conversation.title,
        peer_user_id: peerId,
        peer_username: peer?.username ?? null,
        peer_display_name: peer?.displayName ?? conversation.title,
        peer_online: peer?.online ?? false,
        last_message_content: last?.content ?? null,
        last_message_at: last?.createdAt ?? null,
        unread_count: 0
      };
    })
  };
}
function getMessages(store, conn, params) {
  const me = requireUser(store, conn);
  const conversationId = String(params[0] ?? "");
  if (!store.members.get(conversationId)?.has(me.id)) {
    throw new Error("not a conversation member");
  }
  return {
    rows: store.messages.filter((message) => message.conversationId === conversationId).map((message) => {
      const sender = userById(store, message.senderId);
      return {
        id: message.id,
        conversation_id: message.conversationId,
        sender_id: message.senderId,
        sender_username: sender?.username ?? null,
        sender_display_name: sender?.displayName ?? null,
        client_id: message.clientId,
        type: message.type,
        content: message.content,
        created_at: message.createdAt
      };
    })
  };
}
function sendMessage(store, conn, params) {
  const me = requireUser(store, conn);
  const conversationId = String(params[0] ?? "");
  const clientId = String(params[1] ?? newId(store));
  const content = String(params[2] ?? "");
  if (!store.members.get(conversationId)?.has(me.id)) {
    throw new Error("not a conversation member");
  }
  const existing = store.messages.find((message2) => message2.senderId === me.id && message2.clientId === clientId);
  if (existing) {
    return {
      rows: [
        {
          id: existing.id,
          conversation_id: existing.conversationId,
          sender_id: existing.senderId,
          client_id: existing.clientId,
          type: existing.type,
          content: existing.content,
          created_at: existing.createdAt,
          duplicate: true
        }
      ]
    };
  }
  const message = addMessage(store, conversationId, me.id, content, (/* @__PURE__ */ new Date()).toISOString());
  message.clientId = clientId;
  return {
    rows: [
      {
        id: message.id,
        conversation_id: message.conversationId,
        sender_id: message.senderId,
        client_id: clientId,
        type: message.type,
        content: message.content,
        created_at: message.createdAt,
        duplicate: false
      }
    ]
  };
}
function openContext(store, conn, params) {
  requireUser(store, conn);
  return {
    rows: [
      {
        context_id: CTX_AR,
        conversation_id: CONV_AR,
        tenant_id: String(params[0] ?? TENANT),
        type: String(params[1] ?? "access_request"),
        external_id: String(params[2] ?? "AR-123"),
        metadata: {}
      }
    ]
  };
}
function syncEvents(store, conn, params) {
  const me = requireUser(store, conn);
  const conversationId = String(params[0] ?? "");
  const after = Number(params[1] ?? 0);
  if (!store.members.get(conversationId)?.has(me.id)) {
    throw new Error("not a conversation member");
  }
  return {
    rows: store.events.filter((event) => event.conversationId === conversationId && event.sequence > after).map((event) => ({
      id: event.id,
      conversation_id: event.conversationId,
      tenant_id: event.tenantId,
      sequence: event.sequence,
      type: event.type,
      actor_id: event.actorId,
      payload: event.payload,
      created_at: event.createdAt
    }))
  };
}
function dispatch(store, conn, sqlText, params) {
  const name = sqlText.match(FN)?.[0]?.toLowerCase() ?? "";
  switch (name) {
    case "auth.login":
      return login(store, conn, params);
    case "auth.resume_session":
      return resume(store, conn, params);
    case "auth.logout":
      conn.session = null;
      return { rows: [{ logout: true }] };
    case "auth.list_tenants":
      requireUser(store, conn);
      return listTenants();
    case "auth.select_tenant":
      requireUser(store, conn);
      return { rows: [{ select_tenant: String(params[0] ?? TENANT) }] };
    case "auth.current_tenant_id":
      requireUser(store, conn);
      return { rows: [{ current_tenant_id: TENANT }] };
    case "chat.get_conversations":
      return getConversations(store, conn);
    case "chat.get_messages":
    case "chat.get_messages_after":
      return getMessages(store, conn, params);
    case "chat.send_message":
      return sendMessage(store, conn, params);
    case "efelant.open_context":
      return openContext(store, conn, params);
    case "efelant.sync_events":
    case "efelant.sync_context_events":
      return syncEvents(store, conn, name === "efelant.sync_context_events" ? [CONV_AR, params[3] ?? 0] : params);
    default:
      throw new Error(`memory transport: unsupported ${name || sqlText}`);
  }
}
var MEMORY_IDS = {
  tenant: TENANT,
  alice: ALICE,
  bob: BOB,
  charlie: CHARLIE,
  convBob: CONV_BOB,
  convCharlie: CONV_CHARLIE,
  convAr: CONV_AR
};
function bindMemory(store) {
  const conn = { session: null };
  return {
    async query(sqlText, params = []) {
      return dispatch(store, conn, sqlText, params);
    }
  };
}
function createMemoryTransport() {
  return bindMemory(seedStore());
}
function createMemoryHub() {
  const store = seedStore();
  return {
    open() {
      return bindMemory(store);
    }
  };
}

// src/types.ts
var EVENT_TYPES = [
  "message.created",
  "message.updated",
  "message.deleted",
  "status.changed",
  "member.joined",
  "member.left",
  "reaction.updated",
  "read.updated",
  "assignment.changed",
  "approval.requested",
  "approval.granted",
  "attachment.created",
  "system.notice",
  "conversation.updated",
  "receipt.updated"
];
export {
  EVENT_TYPES,
  EfelantAuthError,
  EfelantClient,
  EfelantError,
  EfelantForbiddenError,
  MEMORY_IDS,
  createGatewayTransport,
  createMemoryHub,
  createMemoryTransport,
  errorFromSql,
  sql
};
//# sourceMappingURL=efelant.esm.js.map
