-- Application roles. Passwords are assigned in 002b_passwords.sh from env.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'efelant_owner') THEN
    CREATE ROLE efelant_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT BYPASSRLS;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'efelant_migrator') THEN
    CREATE ROLE efelant_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'efelant_app') THEN
    CREATE ROLE efelant_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS CONNECTION LIMIT 100;
  END IF;
END
$$;

GRANT efelant_owner TO efelant_migrator;

GRANT CONNECT ON DATABASE efelant TO efelant_owner;
GRANT CONNECT ON DATABASE efelant TO efelant_migrator;
GRANT CONNECT ON DATABASE efelant TO efelant_app;

ALTER ROLE efelant_app SET statement_timeout = '15s';
ALTER ROLE efelant_app SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE efelant_app SET lock_timeout = '5s';
ALTER ROLE efelant_app SET search_path = '';
ALTER ROLE efelant_app SET application_name = 'efelant';

ALTER ROLE efelant_migrator SET search_path = '';
ALTER ROLE efelant_owner SET search_path = '';

ALTER ROLE efelant_app PASSWORD 'efelant_app_dev_password';
ALTER ROLE efelant_migrator PASSWORD 'efelant_migrator_dev_password';

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM efelant_app;
GRANT USAGE ON SCHEMA public TO efelant_owner, efelant_migrator;
