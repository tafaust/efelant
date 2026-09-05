import type { EfelantTransport, QueryResult, SqlValue } from "./transport.js";

const FN = /(auth|chat|efelant)\.[a-z_]+/i;

const TENANT = "00000000-0000-4000-8000-000000000001";
const ALICE = "00000000-0000-4000-8000-000000000002";
const BOB = "00000000-0000-4000-8000-000000000003";
const CHARLIE = "00000000-0000-4000-8000-000000000004";
const CONV_BOB = "00000000-0000-4000-8000-000000000010";
const CONV_CHARLIE = "00000000-0000-4000-8000-000000000011";
const CONV_AR = "00000000-0000-4000-8000-000000000012";
const CTX_AR = "00000000-0000-4000-8000-000000000020";

interface User {
  id: string;
  username: string;
  displayName: string;
  password: string;
  online: boolean;
}

interface Message {
  id: string;
  conversationId: string;
  senderId: string;
  clientId: string;
  type: string;
  content: string;
  createdAt: string;
}

interface EventRow {
  id: string;
  conversationId: string;
  tenantId: string;
  sequence: number;
  type: string;
  actorId: string | null;
  payload: Record<string, unknown>;
  createdAt: string;
}

interface Conversation {
  id: string;
  type: string;
  title: string;
  peerUserId: string | null;
}

interface Store {
  users: User[];
  conversations: Conversation[];
  members: Map<string, Set<string>>;
  messages: Message[];
  events: EventRow[];
  sequences: Map<string, number>;
  session: { userId: string; token: string; deviceId: string } | null;
  next: number;
}

function iso(offsetSec = 0): string {
  return new Date(Date.parse("2026-09-05T10:00:00Z") + offsetSec * 1000).toISOString();
}

function newId(store: Store): string {
  store.next += 1;
  return `00000000-0000-4000-8000-${String(store.next).padStart(12, "0")}`;
}

function requireUser(store: Store): User {
  if (!store.session) {
    throw new Error("not authenticated");
  }
  const user = store.users.find((item) => item.id === store.session?.userId);
  if (!user) {
    throw new Error("not authenticated");
  }
  return user;
}

function seedStore(): Store {
  const store: Store = {
    users: [
      { id: ALICE, username: "alice", displayName: "Alice", password: "password123", online: true },
      { id: BOB, username: "bob", displayName: "Bob", password: "password123", online: true },
      { id: CHARLIE, username: "charlie", displayName: "Charlie", password: "password123", online: false },
    ],
    conversations: [
      { id: CONV_BOB, type: "direct", title: "Bob", peerUserId: BOB },
      { id: CONV_CHARLIE, type: "direct", title: "Charlie", peerUserId: CHARLIE },
      { id: CONV_AR, type: "group", title: "AR-123", peerUserId: null },
    ],
    members: new Map([
      [CONV_BOB, new Set([ALICE, BOB])],
      [CONV_CHARLIE, new Set([ALICE, CHARLIE])],
      [CONV_AR, new Set([ALICE, BOB])],
    ]),
    messages: [],
    events: [],
    sequences: new Map(),
    session: null,
    next: 100,
  };

  addMessage(store, CONV_BOB, BOB, "Can you look at AR-123?", iso(0));
  addMessage(store, CONV_BOB, ALICE, "In the same transaction as the approve.", iso(30));
  addEvent(store, CONV_AR, "status.changed", BOB, { status: "approved", message: "approved the request" }, iso(60));
  addMessage(store, CONV_AR, BOB, "approved the request", iso(60));
  return store;
}

function addMessage(store: Store, conversationId: string, senderId: string, content: string, createdAt: string): Message {
  const message: Message = {
    id: newId(store),
    conversationId,
    senderId,
    clientId: newId(store),
    type: "text",
    content,
    createdAt,
  };
  store.messages.push(message);
  addEvent(
    store,
    conversationId,
    "message.created",
    senderId,
    { content, message_id: message.id, sender_id: senderId },
    createdAt,
  );
  return message;
}

function addEvent(
  store: Store,
  conversationId: string,
  type: string,
  actorId: string | null,
  payload: Record<string, unknown>,
  createdAt: string,
): EventRow {
  const sequence = (store.sequences.get(conversationId) ?? 0) + 1;
  store.sequences.set(conversationId, sequence);
  const event: EventRow = {
    id: newId(store),
    conversationId,
    tenantId: TENANT,
    sequence,
    type,
    actorId,
    payload,
    createdAt,
  };
  store.events.push(event);
  return event;
}

function userById(store: Store, id: string): User | undefined {
  return store.users.find((item) => item.id === id);
}

function login(store: Store, params: SqlValue[]): QueryResult {
  const username = String(params[0] ?? "").trim().toLowerCase();
  const password = String(params[1] ?? "");
  const deviceId = String(params[2] ?? newId(store));
  const user = store.users.find((item) => item.username === username);
  if (!user || user.password !== password) {
    throw new Error("invalid username or password");
  }
  const token = `mem_${user.id}`;
  store.session = { userId: user.id, token, deviceId };
  return {
    rows: [
      {
        user_id: user.id,
        username: user.username,
        display_name: user.displayName,
        session_id: newId(store),
        session_token: token,
        device_id: deviceId,
        expires_at: iso(86400),
      },
    ],
  };
}

function resume(store: Store, params: SqlValue[]): QueryResult {
  const token = String(params[0] ?? "");
  const userId = token.startsWith("mem_") ? token.slice(4) : "";
  const user = store.users.find((item) => item.id === userId);
  if (!user) {
    throw new Error("session not found");
  }
  store.session = { userId: user.id, token, deviceId: store.session?.deviceId ?? newId(store) };
  return {
    rows: [
      {
        user_id: user.id,
        username: user.username,
        display_name: user.displayName,
        session_id: newId(store),
        session_token: token,
        device_id: store.session.deviceId,
        expires_at: iso(86400),
      },
    ],
  };
}

function listTenants(): QueryResult {
  return {
    rows: [{ id: TENANT, slug: "standalone", name: "standalone", role: "owner" }],
  };
}

function getConversations(store: Store): QueryResult {
  const me = requireUser(store);
  return {
    rows: store.conversations
      .filter((conversation) => store.members.get(conversation.id)?.has(me.id))
      .map((conversation) => {
        const peer = conversation.peerUserId ? userById(store, conversation.peerUserId) : undefined;
        const last = [...store.messages].reverse().find((message) => message.conversationId === conversation.id);
        return {
          id: conversation.id,
          type: conversation.type,
          title: conversation.title,
          peer_user_id: conversation.peerUserId,
          peer_username: peer?.username ?? null,
          peer_display_name: peer?.displayName ?? conversation.title,
          peer_online: peer?.online ?? false,
          last_message_content: last?.content ?? null,
          last_message_at: last?.createdAt ?? null,
          unread_count: 0,
        };
      }),
  };
}

function getMessages(store: Store, params: SqlValue[]): QueryResult {
  const me = requireUser(store);
  const conversationId = String(params[0] ?? "");
  if (!store.members.get(conversationId)?.has(me.id)) {
    throw new Error("not a conversation member");
  }
  return {
    rows: store.messages
      .filter((message) => message.conversationId === conversationId)
      .map((message) => {
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
          created_at: message.createdAt,
        };
      }),
  };
}

function sendMessage(store: Store, params: SqlValue[]): QueryResult {
  const me = requireUser(store);
  const conversationId = String(params[0] ?? "");
  const clientId = String(params[1] ?? newId(store));
  const content = String(params[2] ?? "");
  if (!store.members.get(conversationId)?.has(me.id)) {
    throw new Error("not a conversation member");
  }
  const existing = store.messages.find((message) => message.senderId === me.id && message.clientId === clientId);
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
          duplicate: true,
        },
      ],
    };
  }
  const message = addMessage(store, conversationId, me.id, content, new Date().toISOString());
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
        duplicate: false,
      },
    ],
  };
}

function openContext(store: Store, params: SqlValue[]): QueryResult {
  requireUser(store);
  return {
    rows: [
      {
        context_id: CTX_AR,
        conversation_id: CONV_AR,
        tenant_id: String(params[0] ?? TENANT),
        type: String(params[1] ?? "access_request"),
        external_id: String(params[2] ?? "AR-123"),
        metadata: {},
      },
    ],
  };
}

function syncEvents(store: Store, params: SqlValue[]): QueryResult {
  const me = requireUser(store);
  const conversationId = String(params[0] ?? "");
  const after = Number(params[1] ?? 0);
  if (!store.members.get(conversationId)?.has(me.id)) {
    throw new Error("not a conversation member");
  }
  return {
    rows: store.events
      .filter((event) => event.conversationId === conversationId && event.sequence > after)
      .map((event) => ({
        id: event.id,
        conversation_id: event.conversationId,
        tenant_id: event.tenantId,
        sequence: event.sequence,
        type: event.type,
        actor_id: event.actorId,
        payload: event.payload,
        created_at: event.createdAt,
      })),
  };
}

function dispatch(store: Store, sqlText: string, params: SqlValue[]): QueryResult {
  const name = sqlText.match(FN)?.[0]?.toLowerCase() ?? "";
  switch (name) {
    case "auth.login":
      return login(store, params);
    case "auth.resume_session":
      return resume(store, params);
    case "auth.logout":
      store.session = null;
      return { rows: [{ logout: true }] };
    case "auth.list_tenants":
      requireUser(store);
      return listTenants();
    case "auth.select_tenant":
      requireUser(store);
      return { rows: [{ select_tenant: String(params[0] ?? TENANT) }] };
    case "auth.current_tenant_id":
      requireUser(store);
      return { rows: [{ current_tenant_id: TENANT }] };
    case "chat.get_conversations":
      return getConversations(store);
    case "chat.get_messages":
    case "chat.get_messages_after":
      return getMessages(store, params);
    case "chat.send_message":
      return sendMessage(store, params);
    case "efelant.open_context":
      return openContext(store, params);
    case "efelant.sync_events":
    case "efelant.sync_context_events":
      return syncEvents(store, name === "efelant.sync_context_events" ? [CONV_AR, params[3] ?? 0] : params);
    default:
      throw new Error(`memory transport: unsupported ${name || sqlText}`);
  }
}

export const MEMORY_IDS = {
  tenant: TENANT,
  alice: ALICE,
  bob: BOB,
  charlie: CHARLIE,
  convBob: CONV_BOB,
  convCharlie: CONV_CHARLIE,
  convAr: CONV_AR,
};

/**
 * In-memory stand-in for PostgreSQL. Same function names the live client
 * already calls. For Pages and any host that cannot reach the gateway.
 */
export function createMemoryTransport(): EfelantTransport {
  const store = seedStore();
  return {
    async query(sqlText, params = []) {
      return dispatch(store, sqlText, params);
    },
  };
}
