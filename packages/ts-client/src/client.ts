import { sql, type EfelantTransport, type SqlValue } from "./transport.js";
import type {
  AuthSession,
  ContextRecord,
  EfelantContext,
  SyncCursor,
  Tenant,
  TimelineEvent,
} from "./types.js";

export interface EfelantClientOptions {
  transport: EfelantTransport;
}

export class EfelantClient {
  private lastSequence = new Map<string, number>();

  constructor(private readonly options: EfelantClientOptions) {}

  get transport(): EfelantTransport {
    return this.options.transport;
  }

  async login(
    username: string,
    password: string,
    deviceId: string,
    deviceName = "web",
    platform = "web",
  ): Promise<AuthSession> {
    const [row] = await sql<AuthSession>(
      this.transport,
      "SELECT * FROM auth.login($1::text,$2::text,$3::uuid,$4::text,$5::text)",
      [username, password, deviceId, deviceName, platform],
    );
    return row;
  }

  async resume(token: string): Promise<AuthSession> {
    const [row] = await sql<AuthSession>(
      this.transport,
      "SELECT * FROM auth.resume_session($1::text)",
      [token],
    );
    return row;
  }

  async logout(): Promise<void> {
    await sql(this.transport, "SELECT auth.logout()");
  }

  async listTenants(): Promise<Tenant[]> {
    return sql<Tenant>(this.transport, "SELECT id, slug, name, role FROM auth.list_tenants()");
  }

  async selectTenant(tenantId: string): Promise<string> {
    const [row] = await sql<{ select_tenant: string }>(
      this.transport,
      "SELECT auth.select_tenant($1::uuid)",
      [tenantId],
    );
    return row.select_tenant;
  }

  async currentTenantId(): Promise<string | null> {
    const [row] = await sql<{ current_tenant_id: string | null }>(
      this.transport,
      "SELECT auth.current_tenant_id()",
    );
    return row.current_tenant_id;
  }

  async openContext(tenantId: string, context: EfelantContext): Promise<ContextRecord> {
    const [row] = await sql<Record<string, unknown>>(
      this.transport,
      "SELECT * FROM efelant.open_context($1::uuid,$2::text,$3::text,$4::jsonb)",
      [tenantId, context.type, context.externalId, JSON.stringify(context.metadata ?? {})],
    );
    return {
      contextId: String(row.context_id),
      conversationId: String(row.conversation_id),
      tenantId: String(row.tenant_id),
      type: String(row.type),
      externalId: String(row.external_id),
      metadata: (row.metadata ?? {}) as ContextRecord["metadata"],
    };
  }

  async syncEvents(cursor: SyncCursor): Promise<TimelineEvent[]> {
    const rows = await sql<Record<string, unknown>>(
      this.transport,
      "SELECT * FROM efelant.sync_events($1::uuid,$2::bigint)",
      [cursor.conversationId, cursor.lastSequence],
    );
    const events = rows.map(asEvent);
    const last = events.at(-1);
    if (last) {
      this.lastSequence.set(cursor.conversationId, last.sequence);
    }
    return events;
  }

  async syncContext(
    tenantId: string,
    context: EfelantContext,
    lastSequence = 0,
  ): Promise<TimelineEvent[]> {
    const rows = await sql<Record<string, unknown>>(
      this.transport,
      "SELECT * FROM efelant.sync_context_events($1::uuid,$2::text,$3::text,$4::bigint)",
      [tenantId, context.type, context.externalId, lastSequence],
    );
    return rows.map(asEvent);
  }

  cursor(conversationId: string): SyncCursor {
    return {
      conversationId,
      lastSequence: this.lastSequence.get(conversationId) ?? 0,
    };
  }

  async getConversations(): Promise<Record<string, unknown>[]> {
    return sql(this.transport, "SELECT * FROM chat.get_conversations()");
  }

  async getMessages(conversationId: string): Promise<Record<string, unknown>[]> {
    return sql(this.transport, "SELECT * FROM chat.get_messages($1::uuid)", [conversationId]);
  }

  async sendMessage(conversationId: string, clientId: string, content: string): Promise<void> {
    await sql(
      this.transport,
      "SELECT * FROM chat.send_message($1::uuid,$2::uuid,'text',$3::text,NULL,NULL)",
      [conversationId, clientId, content],
    );
  }

  async reconnect(token: string): Promise<AuthSession> {
    return this.resume(token);
  }
}

function asEvent(row: Record<string, unknown>): TimelineEvent {
  return {
    id: String(row.id),
    conversationId: String(row.conversation_id),
    tenantId: String(row.tenant_id),
    sequence: Number(row.sequence),
    type: String(row.type),
    actorId: row.actor_id == null ? null : String(row.actor_id),
    payload: (row.payload ?? {}) as TimelineEvent["payload"],
    createdAt: String(row.created_at),
  };
}

export type { SqlValue };
