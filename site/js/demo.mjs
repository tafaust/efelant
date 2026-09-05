import {
  EfelantClient,
  createGatewayTransport,
  createMemoryTransport,
} from "./vendor/efelant.esm.js";

const DEVICE_KEY = "efelant-demo-device";
const MODE_KEY = "efelant-demo-mode";
const HOST_KEY = "efelant-demo-host";
const USER_KEY = "efelant-demo-user";
const LOCAL_URLS = ["ws://127.0.0.1:8080/ws", "ws://127.0.0.1:5433/"];
const DEFAULT_USER = "alice";
const DEFAULT_PASSWORD = "password123";

function deviceId() {
  const existing = localStorage.getItem(DEVICE_KEY);
  if (existing) {
    return existing;
  }
  const id = crypto.randomUUID();
  localStorage.setItem(DEVICE_KEY, id);
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

function normalizeGateway(raw) {
  const trimmed = raw.trim();
  if (!trimmed) {
    throw new Error("enter a WebSocket URL");
  }
  if (/^wss?:\/\//i.test(trimmed)) {
    return trimmed;
  }
  const http = trimmed.includes("://") ? trimmed : `https://${trimmed}`;
  const parsed = new URL(http);
  const scheme = parsed.protocol === "http:" ? "ws" : "wss";
  const path = parsed.pathname === "/" ? "/ws" : parsed.pathname;
  return `${scheme}://${parsed.host}${path}${parsed.search}`;
}

async function loginWith(transport, username, password) {
  const client = new EfelantClient({ transport });
  const session = await client.login(
    username,
    password,
    deviceId(),
    "site-demo",
    "web"
  );
  return { client, session };
}

async function bootMemory(username, password) {
  const started = await loginWith(createMemoryTransport(), username, password);
  return { ...started, mode: "memory" };
}

async function tryLive(url, username, password) {
  const started = await loginWith(
    createGatewayTransport(url),
    username,
    password
  );
  return { ...started, mode: "live", url };
}

async function connectLocal(username, password) {
  let lastError = new Error("no gateway");
  for (const url of LOCAL_URLS) {
    try {
      return await tryLive(url, username, password);
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
    }
  }
  throw lastError;
}

function tenantLabel(row) {
  return String(row.name || row.slug || row.id);
}

function renderList(root, conversations, activeId, onPick) {
  root.replaceChildren();
  for (const row of conversations) {
    const id = String(field(row, "id"));
    const button = document.createElement("button");
    button.type = "button";
    button.className = `convo${id === activeId ? " active" : ""}`;
    const online = Boolean(row.peer_online);
    const who = document.createElement("div");
    who.className = "who";
    who.textContent = String(
      field(row, "title", "peer_display_name") || "Conversation"
    );
    const snip = document.createElement("div");
    snip.className = "snip";
    snip.textContent = String(
      field(row, "last_message_content") || (online ? "online" : "offline")
    );
    const meta = document.createElement("div");
    meta.append(who, snip);
    const dot = document.createElement("span");
    dot.className = `dot${online ? "" : " off"}`;
    button.append(dot, meta);
    button.addEventListener("click", () => onPick(id));
    root.append(button);
  }
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
    const status =
      event.payload?.status ?? event.payload?.message ?? event.type;
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

async function main() {
  const root = document.querySelector("[data-demo]");
  if (!root) {
    return;
  }
  const listEl = root.querySelector("[data-demo-list]");
  const threadEl = root.querySelector("[data-demo-thread]");
  const form = root.querySelector("[data-demo-form]");
  const hostBtns = [...root.querySelectorAll("[data-host]")];
  const customForm = root.querySelector("[data-demo-custom]");
  const tenantWrap = root.querySelector("[data-demo-tenant-wrap]");
  const tenantSel = root.querySelector("[data-demo-tenant]");
  const noteEl = root.querySelector("[data-demo-note]");

  let bundle = null;
  let activeId = "";
  let me = "";
  let currentMode = "memory";

  function markHost(mode) {
    currentMode = mode;
    hostBtns.forEach((button) => {
      button.setAttribute(
        "aria-selected",
        String(button.getAttribute("data-host") === mode)
      );
    });
    customForm.hidden = mode !== "custom";
  }

  async function fillTenants() {
    const tenants = await bundle.client.listTenants();
    const current = await bundle.client.currentTenantId();
    tenantSel.replaceChildren();
    for (const tenant of tenants) {
      const option = document.createElement("option");
      option.value = String(tenant.id);
      option.textContent = tenantLabel(tenant);
      option.selected = String(tenant.id) === String(current ?? "");
      tenantSel.append(option);
    }
    tenantWrap.hidden = tenants.length === 0;
  }

  async function paint() {
    const conversations = await bundle.client.getConversations();
    if (!activeId && conversations[0]) {
      activeId = String(conversations[0].id);
    }
    renderList(listEl, conversations, activeId, async (id) => {
      activeId = id;
      await paint();
    });
    if (!activeId) {
      threadEl.replaceChildren();
      return;
    }
    const [messages, events] = await Promise.all([
      bundle.client.getMessages(activeId),
      bundle.client.syncEvents({ conversationId: activeId, lastSequence: 0 }),
    ]);
    renderThread(threadEl, timeline(messages, events), me);
  }

  async function start(mode, options = {}) {
    const username = options.username || DEFAULT_USER;
    const password = options.password || DEFAULT_PASSWORD;
    markHost(mode);
    noteEl.textContent = "";
    try {
      if (mode === "memory") {
        bundle = await bootMemory(username, password);
      } else if (mode === "local") {
        bundle = await connectLocal(username, password);
      } else {
        bundle = await tryLive(options.url, username, password);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (mode === "memory") {
        throw error;
      }
      noteEl.textContent =
        mode === "custom"
          ? `Could not reach that host (${message}).`
          : `Local PostgreSQL unavailable (${message}). Using the in-memory SDK.`;
      if (mode === "local") {
        bundle = await bootMemory(username, password);
        markHost("memory");
      } else {
        return;
      }
    }
    localStorage.setItem(MODE_KEY, currentMode);
    if (bundle.url) {
      localStorage.setItem(HOST_KEY, bundle.url);
    }
    if (username !== DEFAULT_USER) {
      localStorage.setItem(USER_KEY, username);
    }
    me = String(field(bundle.session, "user_id", "userId"));
    activeId = "";
    await fillTenants();
    await paint();
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const input = form.querySelector("input");
    const text = input.value.trim();
    if (!text || !activeId || !bundle) {
      return;
    }
    input.value = "";
    await bundle.client.sendMessage(activeId, crypto.randomUUID(), text);
    await paint();
  });

  hostBtns.forEach((button) => {
    button.addEventListener("click", () => {
      const mode = button.getAttribute("data-host");
      if (mode === "custom") {
        markHost("custom");
        customForm.querySelector("[name=host]").focus();
        return;
      }
      if (mode === "memory" || mode === "local") {
        start(mode);
      }
    });
  });

  customForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const data = new FormData(customForm);
    let url;
    try {
      url = normalizeGateway(String(data.get("host") ?? ""));
    } catch (error) {
      noteEl.textContent =
        error instanceof Error ? error.message : String(error);
      return;
    }
    customForm.querySelector("[name=host]").value = url;
    start("custom", {
      url,
      username: String(data.get("user") ?? "").trim() || DEFAULT_USER,
      password: String(data.get("password") ?? "") || DEFAULT_PASSWORD,
    });
  });

  tenantSel.addEventListener("change", async () => {
    if (!bundle || !tenantSel.value) {
      return;
    }
    await bundle.client.selectTenant(tenantSel.value);
    activeId = "";
    await paint();
  });

  const params = new URLSearchParams(location.search);
  const savedHost = customForm.querySelector("[name=host]");
  const savedUser = customForm.querySelector("[name=user]");
  savedHost.value = params.get("host") || localStorage.getItem(HOST_KEY) || "";
  savedUser.value =
    params.get("user") || localStorage.getItem(USER_KEY) || DEFAULT_USER;

  let initial = localStorage.getItem(MODE_KEY) || "memory";
  if (params.has("host")) {
    initial = "custom";
  } else if (params.has("live")) {
    initial = "local";
  }
  if (initial === "custom") {
    markHost("custom");
    if (savedHost.value) {
      await start("custom", {
        url: normalizeGateway(savedHost.value),
        username: savedUser.value,
      });
    }
    return;
  }
  await start(initial === "local" ? "local" : "memory");
}

main().catch((error) => {
  const note = document.querySelector("[data-demo-note]");
  if (note) {
    note.textContent = error instanceof Error ? error.message : String(error);
  }
});
