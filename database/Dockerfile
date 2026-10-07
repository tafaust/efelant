FROM postgres:18-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        openssl \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-17-cron \
        postgresql-server-dev-17 \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY extensions/ /usr/src/efelant-extensions/
RUN make -C /usr/src/efelant-extensions/efelant_rest install \
    && make -C /usr/src/efelant-extensions/efelant_grpc install \
    && rm -rf /usr/src/efelant-extensions

COPY docker-entrypoint-wrap.sh /usr/local/bin/efelant-entrypoint.sh
COPY init/ /docker-entrypoint-initdb.d/

RUN chmod +x /usr/local/bin/efelant-entrypoint.sh /docker-entrypoint-initdb.d/*.sh

ENTRYPOINT ["efelant-entrypoint.sh"]
CMD ["postgres"]
