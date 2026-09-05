import { EfelantClient, createMemoryHub } from "./vendor/efelant.esm.js";

const DEVICE_KEY = "efelant-demo-device";
const PAIR = [
  { key: "alice", username: "alice" },
  { key: "bob", username: "bob" },
];

function deviceId(who) {
  const key = `${DEVICE_KEY}-${who}`;
  const existing = localStorage.getItem(key);
  if (existing) {
    return existing;
  }
  const id = crypto.randomUUID();
  localStorage.setItem(key, id);
  return id;
}

function field(row, ...keys) {
  for (const key of keys) {
    if (row?.[key] != null && row[key] !== "") {
      return row[key];
    }
  }
  return "";
}

async function loginWith(transport, username) {
  const client = new EfelantClient({ transport });
  const session = await client.login(
    username,
    "password123",
    deviceId(username),
    "site-demo",
    "web",
  );
  return { client, session };
}

function renderThread(root, items, me) {
  root.replaceChildren();
  for (const item of items) {
    const bubble = document.createElement("div");
    bubble.className =
      item.kind === "status"
        ? "bubble status"
        : `bubble ${item.senderId === me ? "mine" : "theirs"}`;
    bubble.textContent = item.text;
    root.append(bubble);
  }
  root.scrollTop = root.scrollHeight;
}

function timeline(messages, events) {
  const items = [];
  for (const row of messages) {
    const content = field(row, "content");
    if (!content) {
      continue;
    }
    items.push({
      kind: "message",
      at: String(field(row, "created_at", "createdAt")),
      senderId: String(field(row, "sender_id", "senderId")),
      text: String(content),
    });
  }
  for (const event of events) {
    if (event.type !== "status.changed") {
      continue;
    }
    const status = event.payload?.status ?? event.payload?.message ?? event.type;
    items.push({
      kind: "status",
      at: event.createdAt,
      senderId: event.actorId ?? "",
      text: `status.changed · ${status}`,
    });
  }
  items.sort((a, b) => a.at.localeCompare(b.at));
  return items;
}

function peerMatch(row, username, userId) {
  const peerId = String(field(row, "peer_user_id", "peerUserId"));
  const peerName = String(field(row, "peer_username", "peerUsername")).toLowerCase();
  return peerId === userId || peerName === username;
}

async function findPairId(left, right) {
  const [leftRows, rightRows] = await Promise.all([
    left.client.getConversations(),
    right.client.getConversations(),
  ]);
  const rightId = String(field(right.session, "user_id", "userId"));
  const leftId = String(field(left.session, "user_id", "userId"));
  const fromLeft = leftRows.find((row) => peerMatch(row, right.username, rightId));
  const fromRight = rightRows.find((row) => peerMatch(row, left.username, leftId));
  return String(field(fromLeft, "id") || field(fromRight, "id"));
}

async function main() {
  const root = document.querySelector("[data-demo]");
  if (!root) {
    return;
  }
  const noteEl = root.querySelector("[data-demo-note]");
  const panes = PAIR.map((peer) => {
    const node = root.querySelector(`[data-pane="${peer.key}"]`);
    return {
      ...peer,
      threadEl: node.querySelector("[data-pane-thread]"),
      typingEl: node.querySelector("[data-pane-typing]"),
      form: node.querySelector("[data-pane-form]"),
      client: null,
      me: "",
    };
  });

  let conversationId = "";
  const hub = createMemoryHub();
  for (const pane of panes) {
    const started = await loginWith(hub.open(), pane.username);
    pane.client = started.client;
    pane.session = started.session;
    pane.me = String(field(started.session, "user_id", "userId"));
  }
  conversationId = await findPairId(
    { client: panes[0].client, session: panes[0].session, username: panes[0].username },
    { client: panes[1].client, session: panes[1].session, username: panes[1].username },
  );
  if (!conversationId) {
    noteEl.textContent = "Alice and Bob have no direct conversation.";
  }

  async function paint() {
    if (!conversationId) {
      panes.forEach((pane) => pane.threadEl.replaceChildren());
      return;
    }
    await Promise.all(
      panes.map(async (pane) => {
        const [messages, events] = await Promise.all([
          pane.client.getMessages(conversationId),
          pane.client.syncEvents({ conversationId, lastSequence: 0 }),
        ]);
        renderThread(pane.threadEl, timeline(messages, events), pane.me);
      }),
    );
  }

  const typingTimers = new Map();
  function setTyping(fromKey, on) {
    const other = panes.find((pane) => pane.key !== fromKey);
    if (!other?.typingEl) {
      return;
    }
    other.typingEl.hidden = !on;
  }

  panes.forEach((pane) => {
    const input = pane.form.querySelector("input");
    input.addEventListener("input", () => {
      setTyping(pane.key, input.value.trim().length > 0);
      clearTimeout(typingTimers.get(pane.key));
      typingTimers.set(
        pane.key,
        setTimeout(() => setTyping(pane.key, false), 2000),
      );
    });
    pane.form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const text = input.value.trim();
      if (!text || !conversationId) {
        return;
      }
      input.value = "";
      setTyping(pane.key, false);
      clearTimeout(typingTimers.get(pane.key));
      await pane.client.sendMessage(conversationId, crypto.randomUUID(), text);
      await paint();
    });
  });

  await paint();
}

main().catch((error) => {
  const note = document.querySelector("[data-demo-note]");
  if (note) {
    note.textContent = error instanceof Error ? error.message : String(error);
  }
});
