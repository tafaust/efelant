/* SPDX-License-Identifier: AGPL-3.0-or-later */
#include "postgres.h"

#include "http_front.h"

PG_MODULE_MAGIC;

static int rest_port = 18080;
static char *rest_database = NULL;
static char *rest_listen = NULL;

static void
efelant_rest_handle(EfelantHttpRequest *req, int *status, char **headers_json,
					char **body_json)
{
	Oid types[5] = {TEXTOID, TEXTOID, TEXTOID, JSONBOID, TEXTOID};
	Datum values[5];
	char nulls[5] = {' ', ' ', ' ', ' ', ' '};

	values[0] = CStringGetTextDatum(req->method);
	values[1] = CStringGetTextDatum(req->path);
	values[2] = CStringGetTextDatum(req->query);
	values[3] = DirectFunctionCall1(jsonb_in, CStringGetDatum(req->headers_json));
	if (req->body == NULL)
	{
		values[4] = (Datum)0;
		nulls[4] = 'n';
	}
	else
		values[4] = CStringGetTextDatum(req->body);

	(void)efelant_spi_row(
		"SELECT status, headers, body FROM api.handle_http($1,$2,$3,$4,$5)",
		types, values, nulls, 5, status, headers_json, body_json);
}

PGDLLEXPORT void efelant_rest_main(Datum main_arg);

PGDLLEXPORT void
efelant_rest_main(Datum main_arg)
{
	efelant_serve("efelant_rest", rest_database, rest_listen, rest_port,
				  efelant_rest_handle);
}

void
_PG_init(void)
{
	BackgroundWorker worker;

	DefineCustomIntVariable(
		"efelant_rest.port", "TCP port for the REST worker", NULL, &rest_port,
		18080, 1, 65535, PGC_POSTMASTER, 0, NULL, NULL, NULL);
	DefineCustomStringVariable(
		"efelant_rest.database", "Database the REST worker connects to", NULL,
		&rest_database, "efelant", PGC_POSTMASTER, 0, NULL, NULL, NULL);
	DefineCustomStringVariable(
		"efelant_rest.listen_addresses", "Listen addresses for REST", NULL,
		&rest_listen, "*", PGC_POSTMASTER, 0, NULL, NULL, NULL);

	if (!process_shared_preload_libraries_in_progress)
		return;

	memset(&worker, 0, sizeof(worker));
	worker.bgw_flags =
		BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
	worker.bgw_restart_time = 10;
	snprintf(worker.bgw_name, BGW_MAXLEN, "efelant_rest");
	snprintf(worker.bgw_type, BGW_MAXLEN, "efelant_rest");
	snprintf(worker.bgw_library_name, BGW_MAXLEN, "efelant_rest");
	snprintf(worker.bgw_function_name, BGW_MAXLEN, "efelant_rest_main");
	RegisterBackgroundWorker(&worker);
}
