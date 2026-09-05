import { describe, expect, it } from "vitest";
import { EfelantClient } from "./client.js";
import { MEMORY_IDS, createMemoryHub, createMemoryTransport } from "./memory.js";

describe("createMemoryTransport", () => {
  it("logs in and syncs the seeded Alice↔Bob thread", async () => {
    const client = new EfelantClient({ transport: createMemoryTransport() });
    const session = await client.login("alice", "password123", "00000000-0000-4000-8000-000000000099");
    expect(session.username).toBe("alice");

    const conversations = await client.getConversations();
    expect(conversations.map((row) => row.title)).toContain("Bob");

    const messages = await client.getMessages(MEMORY_IDS.convBob);
    expect(messages.some((row) => String(row.content).includes("AR-123"))).toBe(true);

    await client.sendMessage(MEMORY_IDS.convBob, "00000000-0000-4000-8000-0000000000aa", "ship it");
    const after = await client.getMessages(MEMORY_IDS.convBob);
    expect(after.at(-1)?.content).toBe("ship it");
  });

  it("lets Alice and Bob share one hub", async () => {
    const hub = createMemoryHub();
    const alice = new EfelantClient({ transport: hub.open() });
    const bob = new EfelantClient({ transport: hub.open() });
    await alice.login("alice", "password123", "00000000-0000-4000-8000-0000000000a1");
    await bob.login("bob", "password123", "00000000-0000-4000-8000-0000000000b1");
    expect((await bob.getConversations()).map((row) => row.title)).toContain("Alice");
    await alice.sendMessage(MEMORY_IDS.convBob, "00000000-0000-4000-8000-0000000000ab", "from alice");
    const bobSees = await bob.getMessages(MEMORY_IDS.convBob);
    expect(bobSees.at(-1)?.content).toBe("from alice");
  });

  it("rejects a bad password", async () => {
    const client = new EfelantClient({ transport: createMemoryTransport() });
    await expect(
      client.login("alice", "nope", "00000000-0000-4000-8000-000000000099"),
    ).rejects.toThrow(/invalid username/);
  });
});
