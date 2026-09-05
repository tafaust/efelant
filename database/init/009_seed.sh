#!/bin/bash
set -euo pipefail

# Demo accounts are opt-in. Production compose leaves EFELANT_SEED unset/0.
if [ "${EFELANT_SEED:-0}" != "1" ]; then
  echo "skipping demo seed (EFELANT_SEED=${EFELANT_SEED:-0})"
  exit 0
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
-- Development-only demo accounts. Never use these credentials in production.
-- alice / password123
-- bob / password123
-- charlie / password123

DO $$
DECLARE
  v_alice record;
  v_bob record;
  v_charlie record;
  v_conversation uuid;
  v_message record;
BEGIN
  SELECT * INTO v_alice
    FROM auth.register(
      'alice',
      'password123',
      'Alice',
      '01900000-0000-7000-8000-0000000000a1'::uuid,
      'Seed Phone',
      'linux'
    );

  SELECT * INTO v_bob
    FROM auth.register(
      'bob',
      'password123',
      'Bob',
      '01900000-0000-7000-8000-0000000000b1'::uuid,
      'Seed Laptop',
      'macos'
    );

  SELECT * INTO v_charlie
    FROM auth.register(
      'charlie',
      'password123',
      'Charlie',
      '01900000-0000-7000-8000-0000000000c1'::uuid,
      'Seed Tablet',
      'android'
    );

  PERFORM set_config('efelant.session_token', v_alice.session_token, true);

  SELECT d.conversation_id INTO v_conversation
    FROM chat.create_direct_conversation(v_bob.user_id) d;

  SELECT * INTO v_message
    FROM chat.send_message(
      v_conversation,
      '01900000-0000-7000-8000-00000000f001'::uuid,
      'text',
      'hey bob — welcome to efelant. no backend, just postgres.',
      NULL,
      NULL
    );

  PERFORM set_config('efelant.session_token', v_bob.session_token, true);
  PERFORM chat.mark_read(v_conversation, v_message.id);

  PERFORM set_config('efelant.session_token', '', true);

  RAISE NOTICE 'seeded alice, bob, charlie and one direct conversation';
END
$$;
SQL
