# SPDX-License-Identifier: AGPL-3.0-or-later
"""Browser adapter: WebSocket <-> one PostgreSQL session.

No business logic. The client still calls the same SQL functions; this process
exists because browsers cannot open a PostgreSQL TCP socket.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import re
import uuid
from datetime import date, datetime
from decimal import Decimal
from http import HTTPStatus

import asyncpg
import websockets
from websockets.asyncio.server import ServerConnection
from websockets.http11 import Request

PORT = int(os.environ.get("EFELANT_WS_PORT", "5433"))
MAX_CONNECTIONS = int(os.environ.get("EFELANT_WS_MAX_CONNECTIONS", "80"))
MAX_MESSAGE_BYTES = int(os.environ.get("EFELANT_WS_MAX_MESSAGE_BYTES", str(20 * 1024 * 1024)))
STATEMENT_TIMEOUT = os.environ.get("EFELANT_DB_STATEMENT_TIMEOUT", "15s")
if not re.fullmatch(r"\d+(ms|s|min)", STATEMENT_TIMEOUT):
    raise SystemExit("EFELANT_DB_STATEMENT_TIMEOUT must look like 15s")

_origin_raw = os.environ.get("EFELANT_WS_ORIGINS", "").strip()
ORIGINS: list[str] | None
if not _origin_raw or _origin_raw == "*":
    ORIGINS = None
else:
    ORIGINS = [item.strip() for item in _origin_raw.split(",") if item.strip()]

_ssl_mode = os.environ.get("EFELANT_DB_SSLMODE", "disable")
PG = dict(
    host=os.environ.get("EFELANT_DB_HOST", "postgres"),
    port=int(os.environ.get("EFELANT_DB_PORT", "5432")),
    database=os.environ.get("EFELANT_DB_NAME", "efelant"),
    user=os.environ.get("EFELANT_DB_USER", "efelant_app"),
    password=os.environ.get("EFELANT_DB_PASSWORD", "efelant_app_dev_password"),
    ssl=False if _ssl_mode == "disable" else True,
)

NAMED = re.compile(r"@([A-Za-z_][A-Za-z0-9_]*)")
ACTIVE = 0
ACTIVE_LOCK = asyncio.Lock()


def decode_param(value):
    if isinstance(value, dict) and "__bytea" in value:
        return base64.b64decode(value["__bytea"])
    return value


def encode_value(value):
    if value is None:
        return None
    if isinstance(value, memoryview):
        value = value.tobytes()
    if isinstance(value, (bytes, bytearray)):
        return {"__bytea": base64.b64encode(bytes(value)).decode("ascii")}
    if isinstance(value, uuid.UUID):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, list):
        return [encode_value(item) for item in value]
    return value


def named_sql(sql: str, params: dict):
    names: list[str] = []

    def repl(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in names:
            names.append(name)
        return f"${names.index(name) + 1}"

    converted = NAMED.sub(repl, sql)
    args = [decode_param(params[name]) for name in names]
    return converted, args


async def process_request(connection: ServerConnection, request: Request):
    path = request.path.split("?", 1)[0]
    if path in {"/health", "/ready"}:
        return connection.respond(HTTPStatus.OK, "ok\n")
    async with ACTIVE_LOCK:
        if ACTIVE >= MAX_CONNECTIONS:
            return connection.respond(HTTPStatus.SERVICE_UNAVAILABLE, "too many sessions\n")
    return None


async def handle(websocket):
    global ACTIVE
    async with ACTIVE_LOCK:
        ACTIVE += 1
    conn = await asyncpg.connect(**PG)
    await conn.execute("SELECT set_config('application_name', 'efelant/web', false)")
    await conn.execute(f"SET statement_timeout = '{STATEMENT_TIMEOUT}'")

    async def notify_cb(_conn, _pid, channel, payload):
        try:
            await websocket.send(
                json.dumps({"notify": {"channel": channel, "payload": payload}})
            )
        except Exception:
            pass

    await conn.add_listener("efelant_events", notify_cb)
    listening = {"efelant_events"}

    try:
        async for raw in websocket:
            message = json.loads(raw)
            request_id = message.get("id")
            try:
                if message.get("listen"):
                    channel = message["listen"]
                    if channel not in listening:
                        await conn.add_listener(channel, notify_cb)
                        listening.add(channel)
                    await websocket.send(json.dumps({"id": request_id, "ok": True}))
                    continue

                sql = message["sql"]
                raw_params = message.get("params")
                if isinstance(raw_params, list):
                    converted = sql
                    args = [decode_param(item) for item in raw_params]
                else:
                    converted, args = named_sql(sql, raw_params or {})
                rows = await conn.fetch(converted, *args)
                encoded = [
                    {key: encode_value(row[key]) for key in row.keys()} for row in rows
                ]
                await websocket.send(json.dumps({"id": request_id, "rows": encoded}))
            except Exception as exc:  # noqa: BLE001
                await websocket.send(json.dumps({"id": request_id, "error": str(exc)}))
    finally:
        await conn.close()
        async with ACTIVE_LOCK:
            ACTIVE -= 1


async def main():
    async with websockets.serve(
        handle,
        "0.0.0.0",
        PORT,
        max_size=MAX_MESSAGE_BYTES,
        origins=ORIGINS,
        process_request=process_request,
    ):
        print(
            f"efelant web-gateway listening on :{PORT} "
            f"(max_connections={MAX_CONNECTIONS})",
            flush=True,
        )
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
