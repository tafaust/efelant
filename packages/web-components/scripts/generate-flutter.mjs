import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const docsPath = join(root, "../dist/docs.json");
const outDir = join(root, "../../flutter/lib/src/generated");

const fallback = {
  components: [
    {
      tag: "efelant-conversation",
      props: [
        { name: "tenantId", type: "string", required: true },
        { name: "conversationId", type: "string" },
        { name: "contextType", type: "string" },
        { name: "externalId", type: "string" },
      ],
      events: [],
    },
    {
      tag: "efelant-conversation-list",
      props: [{ name: "tenantId", type: "string" }],
      events: [],
    },
    {
      tag: "efelant-composer",
      props: [
        { name: "placeholder", type: "string" },
        { name: "disabled", type: "boolean" },
      ],
      events: [{ event: "efelantSend", detail: "string" }],
    },
    {
      tag: "efelant-context-feed",
      props: [
        { name: "tenantId", type: "string", required: true },
        { name: "contextType", type: "string", required: true },
        { name: "externalId", type: "string", required: true },
      ],
      events: [],
    },
    {
      tag: "efelant-status-event",
      props: [
        { name: "status", type: "string" },
        { name: "message", type: "string" },
      ],
      events: [],
    },
    {
      tag: "efelant-unread-badge",
      props: [{ name: "count", type: "number" }],
      events: [],
    },
  ],
};

function pascal(tag) {
  return tag
    .split("-")
    .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
    .join("");
}

function dartType(type) {
  const t = String(type).toLowerCase();
  if (t.includes("bool")) {
    return "bool";
  }
  if (t.includes("number") || t.includes("int")) {
    return "int";
  }
  return "String";
}

function readDocs() {
  try {
    const raw = JSON.parse(readFileSync(docsPath, "utf8"));
    const components = (raw.components ?? []).map((c) => ({
      tag: c.tag,
      props: (c.props ?? []).map((p) => ({
        name: p.name,
        type: p.type,
        required: Boolean(p.required),
      })),
      events: (c.events ?? []).map((e) => ({
        event: e.event,
        detail: e.detail,
      })),
    }));
    return { components };
  } catch {
    return fallback;
  }
}

const docs = readDocs();
mkdirSync(outDir, { recursive: true });

const catalog = [
  "// GENERATED from Stencil docs-json. Do not edit.",
  "class StencilComponentSpec {",
  "  const StencilComponentSpec({required this.tag, required this.props, required this.events});",
  "  final String tag;",
  "  final List<String> props;",
  "  final List<String> events;",
  "}",
  "",
  "const stencilComponentCatalog = <StencilComponentSpec>[",
  ...docs.components.map((c) => {
    const props = c.props.map((p) => `'${p.name}'`).join(", ");
    const events = c.events.map((e) => `'${e.event}'`).join(", ");
    return `  StencilComponentSpec(tag: '${c.tag}', props: [${props}], events: [${events}]),`;
  }),
  "];",
  "",
].join("\n");

writeFileSync(join(outDir, "catalog.g.dart"), catalog);

const widgetLines = [
  "// GENERATED from Stencil component contracts. Do not edit.",
  "// Official Stencil outputs are React / Angular / Vue / Ember.",
  "// Flutter has no first-party target; this repo emits Dart facades",
  "// that wrap the native widgets and keep the same public props.",
  "import 'package:flutter/material.dart';",
  "",
  "import '../models.dart';",
  "import '../widgets/efelant_composer.dart';",
  "import '../widgets/efelant_context_feed.dart';",
  "import '../widgets/efelant_conversation.dart';",
  "import '../widgets/efelant_conversation_list.dart';",
  "import '../widgets/efelant_status_event.dart';",
  "import '../widgets/efelant_unread_badge.dart';",
  "",
];

for (const c of docs.components) {
  const name = `${pascal(c.tag)}Element`;
  switch (c.tag) {
    case "efelant-conversation":
      widgetLines.push(
        `/// Facade for the ${c.tag} Stencil element.`,
        `class ${name} extends StatelessWidget {`,
        `  const ${name}({`,
        "    super.key,",
        "    required this.tenantId,",
        "    this.conversationId,",
        "    this.contextType,",
        "    this.externalId,",
        "    this.child,",
        "  });",
        "  final String tenantId;",
        "  final String? conversationId;",
        "  final String? contextType;",
        "  final String? externalId;",
        "  final Widget? child;",
        "  @override",
        "  Widget build(BuildContext context) {",
        "    return EfelantConversation(",
        "      tenantId: tenantId,",
        "      conversationId: conversationId,",
        "      context: contextType == null || externalId == null",
        "          ? null",
        "          : EfelantContext(type: contextType!, externalId: externalId!),",
        "      child: child,",
        "    );",
        "  }",
        "}",
        ""
      );
      break;
    case "efelant-conversation-list":
      widgetLines.push(
        `class ${name} extends StatelessWidget {`,
        `  const ${name}({super.key, this.tenantId, this.children = const []});`,
        "  final String? tenantId;",
        "  final List<Widget> children;",
        "  @override",
        "  Widget build(BuildContext context) {",
        "    return EfelantConversationList(tenantId: tenantId, children: children);",
        "  }",
        "}",
        ""
      );
      break;
    case "efelant-composer":
      widgetLines.push(
        `class ${name} extends StatelessWidget {`,
        `  const ${name}({`,
        "    super.key,",
        "    required this.onSend,",
        "    this.placeholder = 'Message',",
        "    this.disabled = false,",
        "  });",
        "  final ValueChanged<String> onSend;",
        "  final String placeholder;",
        "  final bool disabled;",
        "  @override",
        "  Widget build(BuildContext context) {",
        "    return EfelantComposer(onSend: onSend, enabled: !disabled, placeholder: placeholder);",
        "  }",
        "}",
        ""
      );
      break;
    case "efelant-context-feed":
      widgetLines.push(
        `class ${name} extends StatelessWidget {`,
        `  const ${name}({`,
        "    super.key,",
        "    required this.tenantId,",
        "    required this.contextType,",
        "    required this.externalId,",
        "    this.events = const [],",
        "  });",
        "  final String tenantId;",
        "  final String contextType;",
        "  final String externalId;",
        "  final List<EfelantTimelineEvent> events;",
        "  @override",
        "  Widget build(BuildContext context) {",
        "    return EfelantContextFeed(",
        "      tenantId: tenantId,",
        "      context: EfelantContext(type: contextType, externalId: externalId),",
        "      events: events,",
        "    );",
        "  }",
        "}",
        ""
      );
      break;
    case "efelant-status-event":
      widgetLines.push(
        `class ${name} extends StatelessWidget {`,
        `  const ${name}({super.key, this.status = '', this.message = ''});`,
        "  final String status;",
        "  final String message;",
        "  @override",
        "  Widget build(BuildContext context) {",
        "    return EfelantStatusEvent(status: status, message: message);",
        "  }",
        "}",
        ""
      );
      break;
    case "efelant-unread-badge":
      widgetLines.push(
        `class ${name} extends StatelessWidget {`,
        `  const ${name}({super.key, this.count = 0});`,
        "  final int count;",
        "  @override",
        "  Widget build(BuildContext context) {",
        "    return EfelantUnreadBadge(count: count);",
        "  }",
        "}",
        ""
      );
      break;
    default: {
      const unused = dartType("string");
      widgetLines.push(
        `// Unmapped Stencil tag ${c.tag} (${unused}). Add a facade.`,
        ""
      );
      break;
    }
  }
}

writeFileSync(join(outDir, "stencil_widgets.g.dart"), widgetLines.join("\n"));
console.log(`flutter bindings: ${docs.components.length} components`);
