export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

export interface Tenant {
  id: string;
  slug: string;
  name: string;
  role: string;
}

export interface EfelantContext {
  type: string;
  externalId: string;
  metadata?: Record<string, Json>;
}

export interface ContextRecord {
  contextId: string;
  conversationId: string;
  tenantId: string;
  type: string;
  externalId: string;
  metadata: Record<string, Json>;
}

export interface TimelineEvent {
  id: string;
  conversationId: string;
  tenantId: string;
  sequence: number;
  type: string;
  actorId: string | null;
  payload: Record<string, Json>;
  createdAt: string;
}

export const EVENT_TYPES = [
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
  "receipt.updated",
] as const;

export type EventType = (typeof EVENT_TYPES)[number] | (string & {});

export interface SyncCursor {
  conversationId: string;
  lastSequence: number;
}

export interface AuthSession {
  userId: string;
  username: string;
  displayName: string;
  sessionId: string;
  sessionToken?: string;
  deviceId: string;
  expiresAt: string;
}

export interface ConversationSummary {
  conversationId: string;
  [key: string]: Json;
}
