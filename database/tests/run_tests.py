#!/usr/bin/env python3
"""Efelant database integration tests. Run as the Flutter role, not superuser."""

from __future__ import annotations

import json
import os
import sys
import uuid

import psycopg
from psycopg.rows import dict_row


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


APP = dict(
    host=env("EFELANT_DB_HOST", "localhost"),
    port=int(env("EFELANT_DB_PORT", "5432")),
    dbname=env("EFELANT_DB_NAME", "efelant"),
    user=env("EFELANT_DB_USER", "efelant_app"),
    password=env("EFELANT_DB_PASSWORD", "efelant_app_dev_password"),
    autocommit=True,
)

ADMIN = dict(
    host=APP["host"],
    port=APP["port"],
    dbname=APP["dbname"],
    user=env("POSTGRES_USER", "postgres"),
    password=env("POSTGRES_PASSWORD", "efelant_dev_postgres"),
    autocommit=True,
)

passed = 0
failed = 0


def connect_app():
    return psycopg.connect(**APP, row_factory=dict_row)


def connect_admin():
    return psycopg.connect(**ADMIN, row_factory=dict_row)


def uid() -> str:
    return str(uuid.uuid4())


def register(conn, username: str, password: str = "password123", display: str | None = None):
    device = uid()
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT * FROM auth.register(
              %s::text, %s::text, %s::text, %s::uuid, %s::text, %s::text
            )
            """,
            (username, password, display or username.title(), device, "test", "linux"),
        )
        return cur.fetchone()


def login(conn, username: str, password: str, device: str | None = None):
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT * FROM auth.login(
              %s::text, %s::text, %s::uuid, %s::text, %s::text
            )
            """,
            (username, password, device or uid(), "test", "linux"),
        )
        return cur.fetchone()


def resume(conn, token: str):
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM auth.resume_session(%s::text)", (token,))
        return cur.fetchone()


def expect_error(fn, fragment: str):
    try:
        fn()
    except psycopg.Error as exc:
        message = str(exc).lower()
        if fragment.lower() not in message:
            raise AssertionError(f"expected '{fragment}' in '{exc}'") from exc
        return
    raise AssertionError(f"expected error containing '{fragment}'")


def check(name: str, fn):
    global passed, failed
    try:
        fn()
        passed += 1
        print(f"ok  {name}")
    except Exception as exc:  # noqa: BLE001
        failed += 1
        print(f"not ok  {name}: {exc}")


def test_register():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as conn:
        row = register(conn, f"user_{suffix}")
        assert row["user_id"] is not None
        assert row["session_token"]


def test_duplicate_username():
    suffix = uuid.uuid4().hex[:8]
    name = f"dup_{suffix}"
    with connect_app() as conn:
        register(conn, name)
        expect_error(lambda: register(conn, name), "username")


def test_password_auth():
    suffix = uuid.uuid4().hex[:8]
    name = f"pwd_{suffix}"
    with connect_app() as a, connect_app() as b:
        register(a, name, "correcthorse")
        row = login(b, name, "correcthorse")
        assert row["username"] == name


def test_invalid_password():
    suffix = uuid.uuid4().hex[:8]
    name = f"bad_{suffix}"
    with connect_app() as a, connect_app() as b:
        register(a, name, "correcthorse")
        expect_error(lambda: login(b, name, "wrong-password"), "invalid")


def test_session_expiration():
    suffix = uuid.uuid4().hex[:8]
    name = f"exp_{suffix}"
    with connect_app() as conn:
        row = register(conn, name)
        token = row["session_token"]
        session_id = row["session_id"]
    with connect_admin() as admin:
        with admin.cursor() as cur:
            cur.execute(
                """
                UPDATE auth.sessions
                   SET created_at = now() - interval '2 hours',
                       expires_at = now() - interval '1 hour'
                 WHERE id = %s
                """,
                (session_id,),
            )
    with connect_app() as conn:
        expect_error(lambda: resume(conn, token), "expired")


def test_cannot_read_private_conversation():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as bob, connect_app() as eve:
        a = register(alice, f"alice_{suffix}")
        b = register(bob, f"bob_{suffix}")
        register(eve, f"eve_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
        with eve.cursor() as cur:
            expect_error(
                lambda: cur.execute(
                    "SELECT * FROM chat.get_messages(%s::uuid, 20, NULL, NULL)",
                    (conversation_id,),
                ),
                "member",
            )


def test_cannot_send_if_not_member():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as bob, connect_app() as eve:
        a = register(alice, f"alice2_{suffix}")
        b = register(bob, f"bob2_{suffix}")
        register(eve, f"eve2_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
        with eve.cursor() as cur:
            expect_error(
                lambda: cur.execute(
                    """
                    SELECT * FROM chat.send_message(
                      %s::uuid, %s::uuid, 'text', 'nope', NULL, NULL
                    )
                    """,
                    (conversation_id, uid()),
                ),
                "member",
            )


def test_e2ee_ciphertext_and_wraps():
    suffix = uuid.uuid4().hex[:8]
    alice_key = bytes(range(32))
    bob_key = bytes(range(32, 64))
    wrap = b"\x01" + (b"w" * 47)
    ciphertext = b"\x01" + (b"c" * 28)
    with connect_app() as alice, connect_app() as bob, connect_app() as eve:
        a = register(alice, f"alice_e2ee_{suffix}")
        b = register(bob, f"bob_e2ee_{suffix}")
        register(eve, f"eve_e2ee_{suffix}")
        with alice.cursor() as cur:
            cur.execute("SELECT auth.publish_device_key(%s::bytea)", (alice_key,))
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
            cur.execute(
                "SELECT chat.has_conversation_key_wraps(%s::uuid) AS present",
                (conversation_id,),
            )
            assert cur.fetchone()["present"] is False
            cur.execute(
                """
                SELECT * FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', NULL, %s::bytea, NULL
                )
                """,
                (conversation_id, uid(), ciphertext),
            )
            message = cur.fetchone()
            assert message["content"] is None
            cur.execute(
                "SELECT * FROM chat.get_ciphertexts(%s::uuid)",
                (conversation_id,),
            )
            blobs = cur.fetchall()
            assert len(blobs) == 1
            assert bytes(blobs[0]["encrypted_content"]) == ciphertext
            cur.execute(
                """
                SELECT chat.put_conversation_key_wrap(
                  %s::uuid, %s::uuid, %s::bytea
                )
                """,
                (conversation_id, a["device_id"], wrap),
            )
            cur.execute(
                "SELECT chat.has_conversation_key_wraps(%s::uuid) AS present",
                (conversation_id,),
            )
            assert cur.fetchone()["present"] is True
            cur.execute(
                "SELECT wrapped_key FROM chat.get_conversation_key_wrap(%s::uuid)",
                (conversation_id,),
            )
            assert bytes(cur.fetchone()["wrapped_key"]) == wrap
            cur.execute(
                "SELECT device_id FROM chat.get_conversation_key_wraps(%s::uuid)",
                (conversation_id,),
            )
            assert len(cur.fetchall()) == 1
        with bob.cursor() as cur:
            cur.execute("SELECT auth.publish_device_key(%s::bytea)", (bob_key,))
            cur.execute(
                "SELECT * FROM chat.member_device_keys(%s::uuid)",
                (conversation_id,),
            )
            devices = cur.fetchall()
            assert {bytes(row["identity_public_key"]) for row in devices} == {
                alice_key,
                bob_key,
            }
            cur.execute(
                "SELECT wrapped_key FROM chat.get_conversation_key_wrap(%s::uuid)",
                (conversation_id,),
            )
            assert cur.fetchone() is None
        with eve.cursor() as cur:
            expect_error(
                lambda: cur.execute(
                    "SELECT * FROM chat.get_ciphertexts(%s::uuid)",
                    (conversation_id,),
                ),
                "member",
            )
            expect_error(
                lambda: cur.execute("SELECT * FROM auth.device_keys"),
                "permission denied",
            )
            expect_error(
                lambda: cur.execute("SELECT * FROM chat.conversation_key_wraps"),
                "permission denied",
            )


def test_member_can_send():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as bob:
        a = register(alice, f"alice3_{suffix}")
        b = register(bob, f"bob3_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
            cur.execute(
                """
                SELECT * FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', 'hello from alice', NULL, NULL
                )
                """,
                (conversation_id, uid()),
            )
            message = cur.fetchone()
            assert message["content"] == "hello from alice"
            assert message["duplicate"] is False


def test_duplicate_client_id():
    suffix = uuid.uuid4().hex[:8]
    client_id = uid()
    with connect_app() as alice, connect_app() as bob:
        register(alice, f"alice4_{suffix}")
        b = register(bob, f"bob4_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
            cur.execute(
                """
                SELECT * FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', 'once', NULL, NULL
                )
                """,
                (conversation_id, client_id),
            )
            first = cur.fetchone()
            cur.execute(
                """
                SELECT * FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', 'twice', NULL, NULL
                )
                """,
                (conversation_id, client_id),
            )
            second = cur.fetchone()
            assert first["id"] == second["id"]
            assert second["duplicate"] is True
            cur.execute(
                "SELECT count(*) AS n FROM chat.get_messages(%s::uuid, 50, NULL, NULL)",
                (conversation_id,),
            )
            # get_messages is not a count; recount via two sends of same client
            assert first["content"] == "once"


def test_owner_can_edit():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as bob:
        register(alice, f"alice5_{suffix}")
        b = register(bob, f"bob5_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
            cur.execute(
                """
                SELECT id FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', 'draft', NULL, NULL
                )
                """,
                (conversation_id, uid()),
            )
            message_id = cur.fetchone()["id"]
            cur.execute(
                "SELECT content, edited_at FROM chat.edit_message(%s::uuid, %s::text)",
                (message_id, "revised"),
            )
            edited = cur.fetchone()
            assert edited["content"] == "revised"
            assert edited["edited_at"] is not None


def test_other_user_cannot_edit():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as bob:
        register(alice, f"alice6_{suffix}")
        b = register(bob, f"bob6_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
            cur.execute(
                """
                SELECT id FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', 'mine', NULL, NULL
                )
                """,
                (conversation_id, uid()),
            )
            message_id = cur.fetchone()["id"]
        with bob.cursor() as cur:
            expect_error(
                lambda: cur.execute(
                    "SELECT chat.edit_message(%s::uuid, %s::text)",
                    (message_id, "hacked"),
                ),
                "cannot edit",
            )


def test_read_cursor():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as bob:
        register(alice, f"alice7_{suffix}")
        b = register(bob, f"bob7_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
            cur.execute(
                """
                SELECT id FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', 'read me', NULL, NULL
                )
                """,
                (conversation_id, uid()),
            )
            message_id = cur.fetchone()["id"]
        with bob.cursor() as cur:
            cur.execute(
                "SELECT chat.mark_read(%s::uuid, %s::uuid)",
                (conversation_id, message_id),
            )
            cur.execute("SELECT * FROM chat.get_conversations()")
            rows = cur.fetchall()
            match = next(r for r in rows if r["id"] == conversation_id)
            assert match["last_read_message_id"] == message_id
            assert match["unread_count"] == 0


def test_delivery_and_viewed_receipts():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as bob:
        register(alice, f"alice_r_{suffix}")
        b = register(bob, f"bob_r_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
            cur.execute(
                """
                SELECT id FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', 'receipts', NULL, NULL
                )
                """,
                (conversation_id, uid()),
            )
            message_id = cur.fetchone()["id"]
        with bob.cursor() as cur:
            cur.execute(
                "SELECT chat.mark_delivered(%s::uuid, %s::uuid)",
                (conversation_id, message_id),
            )
            cur.execute(
                "SELECT * FROM chat.get_peer_receipts(%s::uuid)",
                (conversation_id,),
            )
            mine = cur.fetchone()
            assert mine["last_delivered_message_id"] is None
        with alice.cursor() as cur:
            cur.execute(
                "SELECT * FROM chat.get_peer_receipts(%s::uuid)",
                (conversation_id,),
            )
            peer = cur.fetchone()
            assert peer["last_delivered_message_id"] == message_id
            assert peer["last_read_message_id"] is None
            cur.execute("SELECT * FROM chat.get_conversations()")
            match = next(r for r in cur.fetchall() if r["id"] == conversation_id)
            assert match["peer_last_delivered_message_id"] == message_id
        with bob.cursor() as cur:
            cur.execute(
                "SELECT chat.mark_read(%s::uuid, %s::uuid)",
                (conversation_id, message_id),
            )
        with alice.cursor() as cur:
            cur.execute(
                "SELECT * FROM chat.get_peer_receipts(%s::uuid)",
                (conversation_id,),
            )
            peer = cur.fetchone()
            assert peer["last_read_message_id"] == message_id


def test_listen_notify():
    suffix = uuid.uuid4().hex[:8]
    listener = connect_app()
    listener.autocommit = True
    try:
        listener.execute("LISTEN efelant_events")
        with connect_app() as alice, connect_app() as bob:
            register(alice, f"alice8_{suffix}")
            b = register(bob, f"bob8_{suffix}")
            with alice.cursor() as cur:
                cur.execute(
                    "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                    (b["user_id"],),
                )
                conversation_id = cur.fetchone()["conversation_id"]
                cur.execute(
                    """
                    SELECT id FROM chat.send_message(
                      %s::uuid, %s::uuid, 'text', 'notify me', NULL, NULL
                    )
                    """,
                    (conversation_id, uid()),
                )
                message_id = cur.fetchone()["id"]

        found = None
        for notify in listener.notifies(timeout=5, stop_after=20):
            payload = json.loads(notify.payload)
            if (
                payload.get("type") == "message.created"
                and payload.get("message_id") == str(message_id)
            ):
                found = payload
                break
        assert found is not None, "did not receive message.created"
        assert "content" not in found
    finally:
        listener.close()


def test_attachment_size_limit():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as bob:
        register(alice, f"alice9_{suffix}")
        b = register(bob, f"bob9_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
            cur.execute(
                """
                SELECT id FROM chat.send_message(
                  %s::uuid, %s::uuid, 'file', 'huge.bin', NULL, NULL
                )
                """,
                (conversation_id, uid()),
            )
            message_id = cur.fetchone()["id"]
            too_big = b"x" * (10 * 1024 * 1024 + 1)
            expect_error(
                lambda: cur.execute(
                    """
                    SELECT chat.upload_attachment(
                      %s::uuid, 'huge.bin', 'application/octet-stream', %s::bytea
                    )
                    """,
                    (message_id, too_big),
                ),
                "maximum size",
            )


def test_removed_member_loses_access():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as admin, connect_app() as member:
        a = register(admin, f"admin_{suffix}")
        m = register(member, f"member_{suffix}")
        with admin.cursor() as cur:
            cur.execute(
                "SELECT chat.create_group(%s::text, %s::uuid[]) AS id",
                ("secrets", [m["user_id"]]),
            )
            conversation_id = cur.fetchone()["id"]
        with member.cursor() as cur:
            cur.execute(
                """
                SELECT * FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', 'i am in', NULL, NULL
                )
                """,
                (conversation_id, uid()),
            )
            assert cur.fetchone()["content"] == "i am in"
        with admin.cursor() as cur:
            cur.execute(
                "SELECT chat.remove_member(%s::uuid, %s::uuid)",
                (conversation_id, m["user_id"]),
            )
        with member.cursor() as cur:
            expect_error(
                lambda: cur.execute(
                    "SELECT * FROM chat.get_messages(%s::uuid, 20, NULL, NULL)",
                    (conversation_id,),
                ),
                "member",
            )


def test_register_joins_standalone_tenant():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as conn:
        register(conn, f"ten_{suffix}")
        with conn.cursor() as cur:
            cur.execute("SELECT auth.current_tenant_id() AS tenant_id")
            tenant = cur.fetchone()["tenant_id"]
            assert tenant is not None
            cur.execute("SELECT slug FROM auth.list_tenants()")
            slugs = [row["slug"] for row in cur.fetchall()]
            assert "standalone" in slugs


def test_cross_tenant_reads_and_writes_are_impossible():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as bob, connect_admin() as admin:
        a = register(alice, f"iso_a_{suffix}")
        b = register(bob, f"iso_b_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
            cur.execute(
                """
                SELECT * FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', 'secret', NULL, NULL
                )
                """,
                (conversation_id, uid()),
            )
        with admin.cursor() as cur:
            cur.execute(
                "SELECT platform.create_tenant(%s, %s) AS id",
                (f"acme-{suffix}", "Acme"),
            )
            other_tenant = cur.fetchone()["id"]
            cur.execute(
                "SELECT platform.add_tenant_member(%s::uuid, %s::uuid, 'member')",
                (other_tenant, b["user_id"]),
            )
        with bob.cursor() as cur:
            cur.execute("SELECT auth.select_tenant(%s::uuid)", (other_tenant,))
            expect_error(
                lambda: cur.execute(
                    "SELECT * FROM chat.get_messages(%s::uuid, 20, NULL, NULL)",
                    (conversation_id,),
                ),
                "member",
            )
            expect_error(
                lambda: cur.execute(
                    """
                    SELECT * FROM chat.send_message(
                      %s::uuid, %s::uuid, 'text', 'cross', NULL, NULL
                    )
                    """,
                    (conversation_id, uid()),
                ),
                "member",
            )
            expect_error(
                lambda: cur.execute(
                    "SELECT * FROM efelant.sync_events(%s::uuid, 0)",
                    (conversation_id,),
                ),
                "member",
            )
            cur.execute("SELECT id, username FROM chat.search_users(%s)", (a["username"],))
            assert cur.fetchall() == []


def test_presence_is_not_session():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as bob, connect_admin() as admin:
        a = register(alice, f"alice_pres_{suffix}")
        b = register(bob, f"bob_pres_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT conversation_id FROM chat.create_direct_conversation(%s::uuid)",
                (b["user_id"],),
            )
            conversation_id = cur.fetchone()["conversation_id"]
            cur.execute("SELECT chat.is_user_online(%s::uuid) AS online", (a["user_id"],))
            assert cur.fetchone()["online"] is False

        with bob.cursor() as cur:
            cur.execute("SELECT peer_online FROM chat.get_conversations()")
            rows = cur.fetchall()
            assert rows and rows[0]["peer_online"] is False

        with alice.cursor() as cur:
            cur.execute("SELECT chat.heartbeat()")
            cur.execute("SELECT chat.is_user_online(%s::uuid) AS online", (a["user_id"],))
            assert cur.fetchone()["online"] is True

        with bob.cursor() as cur:
            cur.execute(
                "SELECT peer_online FROM chat.get_conversations() WHERE id = %s",
                (conversation_id,),
            )
            assert cur.fetchone()["peer_online"] is True

        with alice.cursor() as cur:
            cur.execute("SELECT chat.set_offline() AS online")
            assert cur.fetchone()["online"] is False
            cur.execute("SELECT * FROM chat.get_conversations()")
            assert cur.fetchall()

        token = a["session_token"]
        resume(alice, token)
        with alice.cursor() as cur:
            cur.execute("SELECT chat.is_user_online(%s::uuid) AS online", (a["user_id"],))
            assert cur.fetchone()["online"] is False

        with alice.cursor() as cur:
            cur.execute("SELECT chat.heartbeat()")
        with admin.cursor() as cur:
            cur.execute(
                """
                UPDATE internal.presence
                   SET last_seen_at = now() - interval '31 seconds',
                       status = 'online'
                 WHERE user_id = %s
                """,
                (a["user_id"],),
            )
        with bob.cursor() as cur:
            cur.execute("SELECT chat.heartbeat()")
            cur.execute("SELECT chat.is_user_online(%s::uuid) AS online", (a["user_id"],))
            assert cur.fetchone()["online"] is False

        with alice.cursor() as cur:
            cur.execute("SELECT chat.heartbeat()")
            cur.execute("SELECT auth.logout()")
        with bob.cursor() as cur:
            cur.execute("SELECT chat.is_user_online(%s::uuid) AS online", (a["user_id"],))
            assert cur.fetchone()["online"] is False


def handle_http(conn, method, path, token=None, query="", body=None):
    headers = {}
    if token:
        headers["authorization"] = f"Bearer {token}"
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM api.handle_http(%s, %s, %s, %s::jsonb, %s)",
            (method, path, query, json.dumps(headers), body or ""),
        )
        return cur.fetchone()


def handle_grpc(conn, method, token=None, message=None):
    headers = {}
    if token:
        headers["authorization"] = f"Bearer {token}"
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM api.handle_grpc(%s, %s, %s::jsonb, %s::jsonb)",
            (
                "efelant.v1.Efelant",
                method,
                json.dumps(headers),
                json.dumps(message or {}),
            ),
        )
        return cur.fetchone()


def test_rest_and_grpc_are_sql():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_app() as transport:
        health = handle_http(transport, "GET", "/health")
        assert health["status"] == 200
        assert health["body"]["ok"] is True

        denied = handle_http(transport, "GET", "/v1/tenants")
        assert denied["status"] == 401

        a = register(alice, f"api_{suffix}")
        with alice.cursor() as cur:
            cur.execute(
                "SELECT platform.create_tenant(%s, %s) AS id",
                (f"int_{suffix}", "Integration"),
            )
            tenant_id = str(cur.fetchone()["id"])

        opened = handle_http(
            transport,
            "POST",
            "/v1/contexts",
            token=a["session_token"],
            body=json.dumps(
                {
                    "tenant_id": tenant_id,
                    "type": "ticket",
                    "external_id": f"T-{suffix}",
                    "metadata": {"from": "test"},
                }
            ),
        )
        assert opened["status"] == 200
        assert opened["body"]["external_id"] == f"T-{suffix}"

        created = handle_http(
            transport,
            "POST",
            f"/v1/tenants/{tenant_id}/clients",
            token=a["session_token"],
            body=json.dumps({"name": "erp"}),
        )
        assert created["status"] == 201
        client_token = created["body"]["token"]
        assert client_token.startswith("efl_")

        status = handle_http(
            transport,
            "POST",
            f"/v1/tenants/{tenant_id}/contexts/ticket/T-{suffix}/status",
            token=client_token,
            body=json.dumps({"status": "approved", "message": "ok"}),
        )
        assert status["status"] == 200
        assert status["body"]["sequence"] >= 1

        limited = handle_http(
            transport,
            "POST",
            f"/v1/tenants/{tenant_id}/clients",
            token=a["session_token"],
            body=json.dumps({"name": "readonly", "scopes": ["tenants:read"]}),
        )
        blocked = handle_http(
            transport,
            "POST",
            f"/v1/tenants/{tenant_id}/contexts/ticket/T-{suffix}/status",
            token=limited["body"]["token"],
            body=json.dumps({"status": "rejected"}),
        )
        assert blocked["status"] == 403

        grpc_health = handle_grpc(transport, "Health")
        assert grpc_health["status"] == 200
        assert grpc_health["body"]["ok"] is True

        grpc_open = handle_grpc(
            transport,
            "OpenContext",
            token=client_token,
            message={
                "tenant_id": tenant_id,
                "type": "ticket",
                "external_id": f"T2-{suffix}",
            },
        )
        assert grpc_open["status"] == 200
        assert grpc_open["body"]["external_id"] == f"T2-{suffix}"


def test_context_and_durable_event_sync():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice:
        register(alice, f"ctx_{suffix}")
        with alice.cursor() as cur:
            cur.execute("SELECT auth.current_tenant_id() AS id")
            tenant_id = cur.fetchone()["id"]
            cur.execute(
                """
                SELECT * FROM efelant.open_context(
                  %s::uuid, 'access_request', %s, '{}'::jsonb
                )
                """,
                (tenant_id, f"AR-{suffix}"),
            )
            opened = cur.fetchone()
            conversation_id = opened["conversation_id"]
            cur.execute(
                """
                SELECT * FROM chat.send_message(
                  %s::uuid, %s::uuid, 'text', 'please review', NULL, NULL
                )
                """,
                (conversation_id, uid()),
            )
            cur.execute(
                "SELECT * FROM efelant.sync_events(%s::uuid, 0)",
                (conversation_id,),
            )
            events = cur.fetchall()
            types = [row["type"] for row in events]
            assert "message.created" in types
            assert events[-1]["sequence"] >= 1
            last = events[-1]["sequence"]
            cur.execute(
                "SELECT * FROM efelant.sync_events(%s::uuid, %s)",
                (conversation_id, last),
            )
            assert cur.fetchall() == []


def test_publish_status_is_transactional():
    suffix = uuid.uuid4().hex[:8]
    with connect_app() as alice, connect_admin() as admin:
        register(alice, f"pub_{suffix}")
        with alice.cursor() as cur:
            cur.execute("SELECT auth.current_tenant_id() AS id")
            tenant_id = cur.fetchone()["id"]
        with admin.transaction():
            with admin.cursor() as cur:
                cur.execute(
                    """
                    SELECT * FROM efelant.publish_status(
                      %s::uuid, 'access_request', %s, 'approved',
                      'Access request approved', '{}'::jsonb
                    )
                    """,
                    (tenant_id, f"AR-{suffix}"),
                )
                published = cur.fetchone()
                assert published["sequence"] >= 1
        with alice.cursor() as cur:
            cur.execute(
                """
                SELECT * FROM efelant.sync_context_events(
                  %s::uuid, 'access_request', %s, 0
                )
                """,
                (tenant_id, f"AR-{suffix}"),
            )
            events = cur.fetchall()
            assert any(row["type"] == "status.changed" for row in events)
            assert events[0]["payload"]["status"] == "approved"


def main() -> int:
    tests = [
        ("user can register", test_register),
        ("duplicate username rejected", test_duplicate_username),
        ("password authentication works", test_password_auth),
        ("invalid password rejected", test_invalid_password),
        ("session expiration works", test_session_expiration),
        ("user cannot read another user's private conversation", test_cannot_read_private_conversation),
        ("user cannot send into a conversation they are not a member of", test_cannot_send_if_not_member),
        ("ciphertext and key wraps stay off the table API", test_e2ee_ciphertext_and_wraps),
        ("member can send a message", test_member_can_send),
        ("duplicate client_id does not create duplicate messages", test_duplicate_client_id),
        ("owner can edit own message", test_owner_can_edit),
        ("another user cannot edit the sender's message", test_other_user_cannot_edit),
        ("read cursor works", test_read_cursor),
        ("delivery and viewed receipts", test_delivery_and_viewed_receipts),
        ("LISTEN/NOTIFY event generated", test_listen_notify),
        ("attachment size limit enforced", test_attachment_size_limit),
        ("removed group member loses access", test_removed_member_loses_access),
        ("leftover session is not online", test_presence_is_not_session),
        ("REST and gRPC dispatch through SQL", test_rest_and_grpc_are_sql),
        ("register joins standalone tenant", test_register_joins_standalone_tenant),
        ("cross-tenant reads and writes are impossible", test_cross_tenant_reads_and_writes_are_impossible),
        ("context conversation has durable event sync", test_context_and_durable_event_sync),
        ("publish_status commits with the host transaction", test_publish_status_is_transactional),
    ]
    print(f"1..{len(tests)}")
    for name, fn in tests:
        check(name, fn)
    print(f"# {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
