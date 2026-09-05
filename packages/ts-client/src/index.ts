/* SPDX-License-Identifier: AGPL-3.0-or-later */
export { EfelantClient, type EfelantClientOptions } from "./client.js";
export {
  EfelantError,
  EfelantAuthError,
  EfelantForbiddenError,
  errorFromSql,
} from "./errors.js";
export {
  createGatewayTransport,
  sql,
  type EfelantTransport,
  type QueryResult,
  type SqlValue,
} from "./transport.js";
export { createMemoryHub, createMemoryTransport, MEMORY_IDS } from "./memory.js";
export {
  EVENT_TYPES,
  type AuthSession,
  type ContextRecord,
  type ConversationSummary,
  type EfelantContext,
  type EventType,
  type Json,
  type SyncCursor,
  type Tenant,
  type TimelineEvent,
} from "./types.js";
