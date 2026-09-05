import { describe, expect, it } from "vitest";
import { EfelantClient } from "./client.js";
import { EfelantForbiddenError, errorFromSql } from "./errors.js";
import { EVENT_TYPES, type EfelantTransport, type QueryResult } from "./index.js";

function mockTransport(handler: (sql: string, params: unknown[]) => QueryResult): EfelantTransport {
  return {
    async query(sql, params = []) {
      return handler(sql, params);
    },
  };
}

describe("EfelantClient", () => {
  it("syncs events with a conversation cursor", async () => {
    const calls: { sql: string; params: unknown[] }[] = [];
    const client = new EfelantClient({
      transport: mockTransport((sql, params) => {
        calls.push({ sql, params });
        return {
          rows: [
            {
              id: "e1",
              conversation_id: "c1",
              tenant_id: "t1",
              sequence: 3,
              type: "status.changed",
              actor_id: null,
              payload: { status: "approved" },
              created_at: "2026-09-05T00:00:00Z",
            },
          ],
        };
      }),
    });

    const events = await client.syncEvents({ conversationId: "c1", lastSequence: 2 });
    expect(events).toHaveLength(1);
    expect(events[0]?.type).toBe("status.changed");
    expect(client.cursor("c1").lastSequence).toBe(3);
    expect(calls[0]?.params).toEqual(["c1", 2]);
  });

  it("opens a context conversation", async () => {
    const client = new EfelantClient({
      transport: mockTransport(() => ({
        rows: [
          {
            context_id: "x1",
            conversation_id: "c1",
            tenant_id: "t1",
            type: "access_request",
            external_id: "AR-123",
            metadata: {},
          },
        ],
      })),
    });
    const ctx = await client.openContext("t1", { type: "access_request", externalId: "AR-123" });
    expect(ctx.conversationId).toBe("c1");
    expect(ctx.type).toBe("access_request");
  });

  it("maps authorization failures to typed errors", () => {
    expect(errorFromSql("not a tenant member", "42501")).toBeInstanceOf(EfelantForbiddenError);
  });

  it("exports the shared event vocabulary", () => {
    expect(EVENT_TYPES).toContain("message.created");
    expect(EVENT_TYPES).toContain("status.changed");
    expect(EVENT_TYPES).toContain("approval.granted");
  });
});
