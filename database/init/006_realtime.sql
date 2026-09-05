SET ROLE efelant_owner;
SET search_path = pg_catalog, public, auth, chat, realtime, internal;

CREATE OR REPLACE FUNCTION realtime.notify_message_created()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM realtime.emit(
    'message.created',
    jsonb_build_object(
      'conversation_id', NEW.conversation_id,
      'message_id', NEW.id,
      'user_id', NEW.sender_id
    )
  );
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION realtime.notify_message_updated()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    PERFORM realtime.emit(
      'message.deleted',
      jsonb_build_object(
        'conversation_id', NEW.conversation_id,
        'message_id', NEW.id
      )
    );
  ELSIF NEW IS DISTINCT FROM OLD THEN
    PERFORM realtime.emit(
      'message.updated',
      jsonb_build_object(
        'conversation_id', NEW.conversation_id,
        'message_id', NEW.id
      )
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION realtime.notify_conversation_updated()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM realtime.emit(
    'conversation.updated',
    jsonb_build_object(
      'conversation_id', COALESCE(NEW.conversation_id, OLD.conversation_id, NEW.id, OLD.id)
    )
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER messages_notify_created
  AFTER INSERT ON chat.messages
  FOR EACH ROW
  EXECUTE FUNCTION realtime.notify_message_created();

CREATE TRIGGER messages_notify_updated
  AFTER UPDATE ON chat.messages
  FOR EACH ROW
  EXECUTE FUNCTION realtime.notify_message_updated();

RESET ROLE;
