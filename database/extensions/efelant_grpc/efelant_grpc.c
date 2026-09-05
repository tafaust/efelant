/* SPDX-License-Identifier: AGPL-3.0-or-later */
#include "postgres.h"

#include "http_front.h"

PG_MODULE_MAGIC;

static int grpc_port = 18081;
static char *grpc_database = NULL;
static char *grpc_listen = NULL;

static void
efelant_split_grpc_path(const char *path, char *service, size_t servicelen,
						char *method, size_t methodlen)
{
	const char *slash;
	const char *start = path;

	strlcpy(service, "efelant.v1.Efelant", servicelen);
	strlcpy(method, "", methodlen);
	if (start[0] == '/')
		start++;
	slash = strrchr(start, '/');
	if (slash == NULL || slash == start)
		return;
	if ((size_t)(slash - start) >= servicelen)
		return;
	memcpy(service, start, (size_t)(slash - start));
	service[slash - start] = '\0';
	strlcpy(method, slash + 1, methodlen);
}

static void
efelant_grpc_handle(EfelantHttpRequest *req, int *status, char **headers_json,
					char **body_json)
{
	char service[256];
	char method[128];
	Oid types[4] = {TEXTOID, TEXTOID, JSONBOID, JSONBOID};
	Datum values[4];
	char nulls[4] = {' ', ' ', ' ', ' '};
	const char *msg = req->body == NULL || req->body[0] == '\0' ? "{}" : req->body;

	efelant_split_grpc_path(req->path, service, sizeof(service), method,
							sizeof(method));

	values[0] = CStringGetTextDatum(service);
	values[1] = CStringGetTextDatum(method);
	values[2] = DirectFunctionCall1(jsonb_in, CStringGetDatum(req->headers_json));
	values[3] = DirectFunctionCall1(jsonb_in, CStringGetDatum(msg));

	(void)efelant_spi_row(
		"SELECT status, headers, body FROM api.handle_grpc($1,$2,$3,$4)",
		types, values, nulls, 4, status, headers_json, body_json);
}

PGDLLEXPORT void efelant_grpc_main(Datum main_arg);

PGDLLEXPORT void
efelant_grpc_main(Datum main_arg)
{
	efelant_serve("efelant_grpc", grpc_database, grpc_listen, grpc_port,
				  efelant_grpc_handle);
}

void
_PG_init(void)
{
	BackgroundWorker worker;

	DefineCustomIntVariable(
		"efelant_grpc.port", "TCP port for the Connect/gRPC-JSON worker", NULL,
		&grpc_port, 18081, 1, 65535, PGC_POSTMASTER, 0, NULL, NULL, NULL);
	DefineCustomStringVariable(
		"efelant_grpc.database", "Database the gRPC worker connects to", NULL,
		&grpc_database, "efelant", PGC_POSTMASTER, 0, NULL, NULL, NULL);
	DefineCustomStringVariable(
		"efelant_grpc.listen_addresses", "Listen addresses for gRPC", NULL,
		&grpc_listen, "*", PGC_POSTMASTER, 0, NULL, NULL, NULL);

	if (!process_shared_preload_libraries_in_progress)
		return;

	memset(&worker, 0, sizeof(worker));
	worker.bgw_flags =
		BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
	worker.bgw_restart_time = 10;
	snprintf(worker.bgw_name, BGW_MAXLEN, "efelant_grpc");
	snprintf(worker.bgw_type, BGW_MAXLEN, "efelant_grpc");
	snprintf(worker.bgw_library_name, BGW_MAXLEN, "efelant_grpc");
	snprintf(worker.bgw_function_name, BGW_MAXLEN, "efelant_grpc_main");
	RegisterBackgroundWorker(&worker);
}
