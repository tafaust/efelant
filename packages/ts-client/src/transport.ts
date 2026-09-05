import { errorFromSql } from "./errors.js";

export type SqlValue = string | number | boolean | null | Uint8Array;

export interface QueryResult {
  rows: Record<string, unknown>[];
}

export interface EfelantTransport {
  query(sql: string, params?: SqlValue[]): Promise<QueryResult>;
  listen?(onEvent: (payload: string) => void): Promise<void>;
  close?(): Promise<void>;
}

export async function sql<T extends object>(
  transport: EfelantTransport,
  text: string,
  params: SqlValue[] = [],
): Promise<T[]> {
  try {
    const result = await transport.query(text, params);
    return result.rows as T[];
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    throw errorFromSql(message);
  }
}

/**
 * Browser clients must use a gateway transport. They cannot speak the
 * PostgreSQL wire protocol. The gateway is a session adapter only.
 */
export function createGatewayTransport(url: string): EfelantTransport {
  let socket: WebSocket | undefined;
  let nextId = 1;
  const pending = new Map<
    number,
    { resolve: (value: QueryResult) => void; reject: (error: Error) => void }
  >();

  function ensure(): WebSocket {
    if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) {
      return socket;
    }
    socket = new WebSocket(url);
    socket.addEventListener("message", (event) => {
      const data = JSON.parse(String(event.data)) as {
        id?: number;
        rows?: Record<string, unknown>[];
        error?: string;
      };
      if (data.id == null) {
        return;
      }
      const waiter = pending.get(data.id);
      if (!waiter) {
        return;
      }
      pending.delete(data.id);
      if (data.error) {
        waiter.reject(new Error(data.error));
        return;
      }
      waiter.resolve({ rows: data.rows ?? [] });
    });
    return socket;
  }

  return {
    async query(sqlText, params = []) {
      const ws = ensure();
      if (ws.readyState !== WebSocket.OPEN) {
        await new Promise<void>((resolve, reject) => {
          ws.addEventListener("open", () => resolve(), { once: true });
          ws.addEventListener("error", () => reject(new Error("gateway socket failed")), {
            once: true,
          });
        });
      }
      const id = nextId++;
      return new Promise<QueryResult>((resolve, reject) => {
        pending.set(id, { resolve, reject });
        ws.send(JSON.stringify({ id, sql: sqlText, params }));
      });
    },
    async close() {
      socket?.close();
    },
  };
}
