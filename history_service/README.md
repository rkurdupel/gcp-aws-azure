# History Service

## Responsibility

The history service is a Go application that:

- consumes price messages from RabbitMQ
- inserts prices into PostgreSQL
- serves historical rows for the UI
- serves chart data and min/max statistics

## Runtime

- language: Go
- container port: `5002`
- Docker host access: `http://localhost:5002`

## Endpoints

- `GET /history` - filtered historical rows
- `GET /stats` - highest and lowest price for a coin
- `GET /chart` - chart points for a selected range

## Dependencies

- PostgreSQL on `devops-data`
- RabbitMQ on `devops-data`

## Environment Variables

- `POSTGRES_HOST`
- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASS`
- `POSTGRES_TABLE`
- `RABBITMQ_HOST`
- `RABBITMQ_USER`
- `RABBITMQ_PASS`
- `RABBITMQ_QUEUE`

Current runtime expectations:

- `POSTGRES_HOST=192.168.56.14`
- `RABBITMQ_HOST=192.168.56.14`

## Docker

Start the full stack:

```bash
docker compose up --build
```

Show history logs:

```bash
docker compose logs history
```

Stop the stack:

```bash
docker compose down
```

## Common Problems

### PostgreSQL Write Errors

Likely causes:

- PostgreSQL is not running on `devops-data`
- DB credentials in `.env` are wrong
- `POSTGRES_TABLE` is empty or incorrect

Check:

```bash
docker compose logs history
vagrant ssh devops-data -c "sudo systemctl status postgresql"
```

### RabbitMQ Reconnect Loop

Likely causes:

- RabbitMQ is down
- wrong RabbitMQ user or password
- queue name mismatch

Check:

```bash
docker compose logs history
vagrant ssh devops-data -c "sudo systemctl status rabbitmq-server"
```

### SQL Error Near `(`

One common cause is an empty `POSTGRES_TABLE` value when the service starts.

Check:

```bash
grep POSTGRES_TABLE .env
```

## Notes

- the service creates the target table if it does not already exist
- duplicate inserts within a short time window are skipped
- malformed RabbitMQ messages are NACKed without requeue
- database save failures are NACKed with requeue
- messages are ACKed only after successful processing
