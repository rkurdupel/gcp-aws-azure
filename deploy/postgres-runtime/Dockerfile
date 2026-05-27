FROM postgres:16-bookworm AS postgres-entrypoint

FROM quay.io/tembo/pg16-pgmq@sha256:7f80d046257d585d1af9d19cf28bd355a4b854b0a7d643c02ebbe6b84457868a AS tembo-pgmq

FROM ubuntu:noble@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b

ENV DEBIAN_FRONTEND=noninteractive
ENV PGDATA=/var/lib/postgresql/data
ENV POSTGRES_DB=cognitor
ENV PATH=/usr/lib/postgresql/16/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        gosu \
        locales \
        postgresql-16 \
        postgresql-16-cron \
        tzdata \
    && groupmod -g 70 postgres \
    && usermod -u 70 -g 70 postgres \
    && rm -rf /var/lib/apt/lists/*

COPY --from=postgres-entrypoint /usr/local/bin/docker-entrypoint.sh /usr/local/bin/
COPY --from=postgres-entrypoint /usr/local/bin/docker-ensure-initdb.sh /usr/local/bin/
COPY --from=postgres-entrypoint /usr/local/bin/docker-enforce-initdb.sh /usr/local/bin/
COPY --from=tembo-pgmq /usr/share/postgresql/16/extension/pgmq* /usr/share/postgresql/16/extension/

RUN mkdir -p "$PGDATA" /docker-entrypoint-initdb.d /var/run/postgresql \
    && chown -R postgres:postgres /var/lib/postgresql /docker-entrypoint-initdb.d /var/run/postgresql \
    && chmod 3777 /var/run/postgresql \
    && printf "shared_preload_libraries = 'pg_cron'\ncron.database_name = 'cognitor'\n" \
        >> /usr/share/postgresql/16/postgresql.conf.sample

VOLUME /var/lib/postgresql/data

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
