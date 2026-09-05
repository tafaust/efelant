DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_cron;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron unavailable: % — expired sessions and stale presence are still purged opportunistically by auth.login and chat.heartbeat', SQLERRM;
    RETURN;
END
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid)
      FROM cron.job
     WHERE jobname IN (
       'efelant-purge-expired',
       'efelant-purge-presence',
       'efelant-purge-attachments'
     );

    PERFORM cron.schedule(
      'efelant-purge-expired',
      '*/15 * * * *',
      $cron$SELECT internal.purge_expired()$cron$
    );
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron schedule skipped: %', SQLERRM;
END
$$;
