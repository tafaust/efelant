/* Shared HTTP/1.1 accept loop for Efelant protocol extensions.
 * Transport only: parse request, SPI into SQL, write response.
 */
#ifndef EFELANT_HTTP_FRONT_H
#define EFELANT_HTTP_FRONT_H

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "access/xact.h"
#include "catalog/pg_type_d.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "tcop/tcopprot.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/jsonb.h"
#include "utils/memutils.h"
#include "utils/fmgrprotos.h"
#include "utils/snapmgr.h"
#include "utils/wait_event.h"

#define EFELANT_MAX_HEADER 8192
#define EFELANT_MAX_BODY (1024 * 1024)
#define EFELANT_MAX_LINE 2048

typedef struct EfelantHttpRequest
{
	char method[16];
	char path[1024];
	char query[1024];
	char headers_json[EFELANT_MAX_HEADER];
	char *body;
	int body_len;
} EfelantHttpRequest;

static void
efelant_json_escape(StringInfo out, const char *src, int len)
{
	int i;

	for (i = 0; i < len; i++)
	{
		unsigned char c = (unsigned char)src[i];

		switch (c)
		{
			case '\\':
				appendStringInfoString(out, "\\\\");
				break;
			case '"':
				appendStringInfoString(out, "\\\"");
				break;
			case '\n':
				appendStringInfoString(out, "\\n");
				break;
			case '\r':
				appendStringInfoString(out, "\\r");
				break;
			case '\t':
				appendStringInfoString(out, "\\t");
				break;
			default:
				if (c < 0x20)
					appendStringInfo(out, "\\u%04x", c);
				else
					appendStringInfoCharMacro(out, (char)c);
				break;
		}
	}
}

static void
efelant_header_key(char *dst, size_t dstsz, const char *src)
{
	size_t i;

	for (i = 0; src[i] != '\0' && i + 1 < dstsz; i++)
	{
		char c = src[i];

		if (c >= 'A' && c <= 'Z')
			c = (char)(c - 'A' + 'a');
		dst[i] = c;
	}
	dst[i] = '\0';
}

static int
efelant_recv_all(int fd, char *buf, int want)
{
	int got = 0;

	while (got < want)
	{
		ssize_t n;
		struct pollfd pfd;

		pfd.fd = fd;
		pfd.events = POLLIN;
		if (poll(&pfd, 1, 5000) <= 0)
			return -1;
		n = recv(fd, buf + got, (size_t)(want - got), 0);
		if (n <= 0)
			return -1;
		got += (int)n;
	}
	return got;
}

static int
efelant_read_request(int fd, EfelantHttpRequest *req)
{
	char head[EFELANT_MAX_HEADER];
	int used = 0;
	char *sep;
	char *line;
	char *save;
	int content_len = 0;
	StringInfoData headers;
	int first = 1;

	req->body = NULL;
	req->body_len = 0;
	req->method[0] = '\0';
	req->path[0] = '/';
	req->path[1] = '\0';
	req->query[0] = '\0';

	while (used < EFELANT_MAX_HEADER - 1)
	{
		ssize_t n;
		struct pollfd pfd;

		pfd.fd = fd;
		pfd.events = POLLIN;
		if (poll(&pfd, 1, 5000) <= 0)
			return -1;
		n = recv(fd, head + used, (size_t)(EFELANT_MAX_HEADER - 1 - used), 0);
		if (n <= 0)
			return -1;
		used += (int)n;
		head[used] = '\0';
		if (strstr(head, "\r\n\r\n") != NULL)
			break;
	}

	sep = strstr(head, "\r\n\r\n");
	if (sep == NULL)
		return -1;
	sep[0] = '\0';

	initStringInfo(&headers);
	appendStringInfoChar(&headers, '{');

	line = strtok_r(head, "\r\n", &save);
	while (line != NULL)
	{
		if (first)
		{
			char *q;
			char meth[16];
			char target[1024];
			char ver[16];

			first = 0;
			if (sscanf(line, "%15s %1023s %15s", meth, target, ver) < 2)
				return -1;
			strlcpy(req->method, meth, sizeof(req->method));
			q = strchr(target, '?');
			if (q != NULL)
			{
				*q = '\0';
				strlcpy(req->query, q + 1, sizeof(req->query));
			}
			strlcpy(req->path, target, sizeof(req->path));
		}
		else
		{
			char *colon = strchr(line, ':');
			char key[128];

			if (colon != NULL)
			{
				*colon = '\0';
				efelant_header_key(key, sizeof(key), line);
				colon += 1;
				while (*colon == ' ')
					colon++;
				if (strcmp(key, "content-length") == 0)
					content_len = atoi(colon);
				if (headers.len > 1)
					appendStringInfoChar(&headers, ',');
				appendStringInfoChar(&headers, '"');
				efelant_json_escape(&headers, key, (int)strlen(key));
				appendStringInfoString(&headers, "\":\"");
				efelant_json_escape(&headers, colon, (int)strlen(colon));
				appendStringInfoChar(&headers, '"');
			}
		}
		line = strtok_r(NULL, "\r\n", &save);
	}
	appendStringInfoChar(&headers, '}');
	strlcpy(req->headers_json, headers.data, sizeof(req->headers_json));
	pfree(headers.data);

	if (content_len < 0 || content_len > EFELANT_MAX_BODY)
		return -1;

	{
		char *extra = sep + 4;
		int extra_len = used - (int)(extra - head);

		req->body = (char *)palloc0((Size)content_len + 1);
		req->body_len = content_len;
		if (extra_len > 0)
		{
			int take = extra_len > content_len ? content_len : extra_len;

			memcpy(req->body, extra, (size_t)take);
			if (content_len > take &&
				efelant_recv_all(fd, req->body + take, content_len - take) < 0)
				return -1;
		}
		else if (content_len > 0 &&
				 efelant_recv_all(fd, req->body, content_len) < 0)
			return -1;
	}
	return 0;
}

static void
efelant_send_response(int fd, int status, const char *hdr_json, const char *body_json)
{
	const char *reason = "OK";
	StringInfoData out;
	int body_len = 0;

	if (status == 201)
		reason = "Created";
	else if (status == 204)
		reason = "No Content";
	else if (status == 400)
		reason = "Bad Request";
	else if (status == 401)
		reason = "Unauthorized";
	else if (status == 403)
		reason = "Forbidden";
	else if (status == 404)
		reason = "Not Found";
	else if (status >= 500)
		reason = "Internal Server Error";

	if (body_json != NULL)
		body_len = (int)strlen(body_json);

	initStringInfo(&out);
	appendStringInfo(&out, "HTTP/1.1 %d %s\r\n", status, reason);
	appendStringInfoString(&out, "connection: close\r\n");
	if (hdr_json != NULL && hdr_json[0] == '{')
	{
		/* Best-effort: emit content-type when present in JSON object. */
		if (strstr(hdr_json, "content-type") != NULL)
			appendStringInfoString(&out, "content-type: application/json\r\n");
		if (strstr(hdr_json, "grpc-status") != NULL)
		{
			const char *p = strstr(hdr_json, "\"grpc-status\"");
			if (p != NULL)
			{
				p = strchr(p + 13, '"');
				if (p != NULL)
				{
					char code[8];
					int i = 0;

					p++;
					while (p[i] != '\0' && p[i] != '"' && i < 7)
					{
						code[i] = p[i];
						i++;
					}
					code[i] = '\0';
					appendStringInfo(&out, "grpc-status: %s\r\n", code);
				}
			}
		}
	}
	else
		appendStringInfoString(&out, "content-type: application/json\r\n");
	appendStringInfo(&out, "content-length: %d\r\n\r\n", body_len);
	if (body_json != NULL)
		appendBinaryStringInfo(&out, body_json, body_len);
	(void)send(fd, out.data, (size_t)out.len, 0);
	pfree(out.data);
}

static int
efelant_listen_socket(const char *listen_addresses, int port)
{
	int fd;
	int one = 1;
	struct sockaddr_in addr;

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		ereport(ERROR, (errmsg("efelant: socket failed: %m")));
	(void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16)port);
	if (listen_addresses == NULL || strcmp(listen_addresses, "*") == 0 ||
		strcmp(listen_addresses, "0.0.0.0") == 0)
		addr.sin_addr.s_addr = htonl(INADDR_ANY);
	else
		addr.sin_addr.s_addr = inet_addr(listen_addresses);
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
		ereport(ERROR, (errmsg("efelant: bind %d failed: %m", port)));
	if (listen(fd, 32) < 0)
		ereport(ERROR, (errmsg("efelant: listen failed: %m")));
	return fd;
}

typedef void (*EfelantHandleFn)(EfelantHttpRequest *req, int *status,
								char **headers_json, char **body_json);

static void
efelant_serve(const char *name, const char *database, const char *listen_addresses,
			  int port, EfelantHandleFn handle)
{
	int listen_fd;
	struct pollfd pfd;

	BackgroundWorkerUnblockSignals();
	BackgroundWorkerInitializeConnection(database, NULL, 0);

	listen_fd = efelant_listen_socket(listen_addresses, port);
	elog(LOG, "%s listening on %s:%d", name, listen_addresses, port);

	pfd.fd = listen_fd;
	pfd.events = POLLIN;

	for (;;)
	{
		int client;
		EfelantHttpRequest req = {0};
		int status = 500;
		char *headers_json = NULL;
		char *body_json = NULL;

		CHECK_FOR_INTERRUPTS();
		if (poll(&pfd, 1, 1000) <= 0)
			continue;
		client = accept(listen_fd, NULL, NULL);
		if (client < 0)
			continue;

		SetCurrentStatementStartTimestamp();
		StartTransactionCommand();
		PG_TRY();
		{
			if (efelant_read_request(client, &req) == 0)
			{
				handle(&req, &status, &headers_json, &body_json);
				efelant_send_response(client, status, headers_json, body_json);
			}
			else
				efelant_send_response(
					client, 400, "{\"content-type\":\"application/json\"}",
					"{\"error\":\"bad request\"}");
			if (req.body != NULL)
				pfree(req.body);
			req.body = NULL;
			if (headers_json != NULL)
				pfree(headers_json);
			headers_json = NULL;
			if (body_json != NULL)
				pfree(body_json);
			body_json = NULL;
			CommitTransactionCommand();
		}
		PG_CATCH();
		{
			ErrorData *edata = CopyErrorData();

			elog(LOG, "%s request failed: %s", name, edata->message);
			FlushErrorState();
			if (IsTransactionOrTransactionBlock())
				AbortCurrentTransaction();
			efelant_send_response(
				client, 500, "{\"content-type\":\"application/json\"}",
				"{\"error\":\"internal error\"}");
		}
		PG_END_TRY();

		close(client);
	}
}

static bool
efelant_spi_row(const char *sql, Oid *argtypes, Datum *values, char *nulls,
				int nargs, int *status, char **headers_json, char **body_json)
{
	int ret;
	bool isnull;
	Datum d;

	SPI_connect();
	PushActiveSnapshot(GetTransactionSnapshot());

	ret = SPI_execute_with_args(sql, nargs, argtypes, values, nulls, false, 1);
	if (ret != SPI_OK_SELECT || SPI_processed != 1)
	{
		PopActiveSnapshot();
		SPI_finish();
		*status = 500;
		*headers_json = pstrdup("{\"content-type\":\"application/json\"}");
		*body_json = pstrdup("{\"error\":\"handler failed\"}");
		return false;
	}

	d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
	*status = isnull ? 500 : DatumGetInt32(d);

	{
		MemoryContext old = MemoryContextSwitchTo(TopMemoryContext);

		d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &isnull);
		if (isnull)
			*headers_json = pstrdup("{}");
		else
			*headers_json =
				pstrdup(DatumGetCString(DirectFunctionCall1(jsonb_out, d)));

		d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3, &isnull);
		if (isnull)
			*body_json = NULL;
		else
			*body_json =
				pstrdup(DatumGetCString(DirectFunctionCall1(jsonb_out, d)));
		MemoryContextSwitchTo(old);
	}

	PopActiveSnapshot();
	SPI_finish();
	return true;
}

#endif
