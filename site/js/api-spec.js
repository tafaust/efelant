(function () {
  const restHost = document.querySelector("[data-api-rest]");
  const grpcHost = document.querySelector("[data-api-grpc]");
  const protoHost = document.querySelector("[data-api-proto]");
  if (!restHost && !grpcHost) {
    return;
  }

  const specUrl = new URL("specs/api.json", window.location.href);
  const openapiUrl = new URL("specs/openapi.json", window.location.href);
  const TAG_ORDER = [
    "Health",
    "Tenants",
    "Contexts",
    "Events",
    "Clients",
    "Spec",
  ];

  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const [key, value] of Object.entries(attrs)) {
        if (key === "className") {
          node.className = value;
        } else if (key === "text") {
          node.textContent = value;
        } else {
          node.setAttribute(key, value);
        }
      }
    }
    for (const child of children ?? []) {
      node.append(child);
    }
    return node;
  }

  function fieldType(field) {
    return field.repeated ? `${field.type}[]` : field.type;
  }

  function fieldTable(fields) {
    if (!fields || fields.length === 0) {
      return el("p", { className: "spec-empty", text: "No fields." });
    }
    const table = el("table", null, [
      el("thead", null, [
        el("tr", null, [
          el("th", { text: "Field" }),
          el("th", { text: "Type" }),
          el("th", { text: "#" }),
        ]),
      ]),
    ]);
    const body = el("tbody");
    for (const field of fields) {
      body.append(
        el("tr", null, [
          el("td", null, [el("code", { text: field.name })]),
          el("td", null, [el("code", { text: fieldType(field) })]),
          el("td", { text: String(field.id) }),
        ])
      );
    }
    table.append(body);
    return table;
  }

  function grpcTag(name) {
    if (name === "Health") {
      return "Health";
    }
    if (/Event|Status|Sync/.test(name)) {
      return "Events";
    }
    if (/Context/.test(name)) {
      return "Contexts";
    }
    if (/Tenant/.test(name)) {
      return "Tenants";
    }
    if (/Client/.test(name)) {
      return "Clients";
    }
    return "Spec";
  }

  function grpcOp(rpc) {
    const details = el("details", { className: "spec-op spec-rpc" });
    details.append(
      el("summary", null, [
        el("span", { className: "verb verb-rpc", text: "RPC" }),
        el("code", { className: "spec-path", text: rpc.name }),
        el("span", {
          className: "spec-sum",
          text: `${rpc.request} → ${rpc.response}`,
        }),
      ])
    );
    const body = el("div", { className: "spec-body" });
    if (rpc.description) {
      body.append(el("p", { text: rpc.description }));
    }
    body.append(
      el("p", {
        className: "spec-auth",
        text: rpc.auth
          ? rpc.scope
            ? `Bearer metadata required. Scope ${rpc.scope}.`
            : "Bearer metadata required."
          : "Public.",
      })
    );
    body.append(el("h4", { text: `Request · ${rpc.request}` }));
    body.append(fieldTable(rpc.requestFields));
    body.append(el("h4", { text: `Response · ${rpc.response}` }));
    body.append(fieldTable(rpc.responseFields));
    details.append(body);
    return details;
  }

  function renderGrpc(spec) {
    if (!grpcHost) {
      return;
    }
    grpcHost.replaceChildren();
    const groups = new Map();
    for (const rpc of spec.grpc) {
      const tag = grpcTag(rpc.name);
      if (!groups.has(tag)) {
        groups.set(tag, []);
      }
      groups.get(tag).push(rpc);
    }
    const tags = [...groups.keys()].sort((a, b) => {
      const rank = (tag) => {
        const i = TAG_ORDER.indexOf(tag);
        return i === -1 ? TAG_ORDER.length : i;
      };
      return rank(a) - rank(b);
    });
    for (const tag of tags) {
      const wrap = el("details", { className: "spec-tag", open: "" });
      wrap.append(el("summary", { text: tag }));
      const stack = el("div", { className: "spec-stack" });
      for (const rpc of groups.get(tag)) {
        stack.append(grpcOp(rpc));
      }
      wrap.append(stack);
      grpcHost.append(wrap);
    }
  }

  function mountSwagger() {
    if (!restHost) {
      return;
    }
    if (typeof window.SwaggerUIBundle !== "function") {
      restHost.replaceChildren(
        el("p", {
          text: "Could not load Swagger UI. Open openapi.json, or allow the CDN.",
        })
      );
      return;
    }
    restHost.replaceChildren();
    window.SwaggerUIBundle({
      url: openapiUrl.href,
      domNode: restHost,
      deepLinking: false,
      docExpansion: "list",
      filter: true,
      tryItOutEnabled: false,
      supportedSubmitMethods: [],
      defaultModelsExpandDepth: 0,
      defaultModelExpandDepth: 2,
      validatorUrl: false,
      tagsSorter: (a, b) => TAG_ORDER.indexOf(a) - TAG_ORDER.indexOf(b),
      syntaxHighlight: {
        activated: true,
        theme: "agate",
      },
    });
  }

  mountSwagger();

  fetch(specUrl)
    .then((res) => {
      if (!res.ok) {
        throw new Error(res.statusText);
      }
      return res.json();
    })
    .then((spec) => {
      renderGrpc(spec);
      if (protoHost) {
        protoHost.textContent = spec.proto;
        protoHost.closest("pre")?.setAttribute("data-lang", "proto");
        window.efelantHighlight?.();
      }
    })
    .catch((err) => {
      const msg = `Could not load specs/api.json (${err.message}). Run ./scripts/packages.sh api`;
      if (grpcHost) {
        grpcHost.replaceChildren(el("p", { text: msg }));
      }
    });
})();
