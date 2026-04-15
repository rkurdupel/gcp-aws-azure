# Proxy Service

## Responsibility

The proxy service is a Flask application that:

- fetches live spot prices from Coinbase
- returns the current price to the UI
- publishes price messages to RabbitMQ
- refreshes supported coins in the background

## Runtime

- language: Python 3
- framework: Flask
- container port: `5001`
- Docker host access: `http://localhost:5001`

## Endpoints

- `GET /price/<coin>` - fetch a live price and publish it to RabbitMQ

Supported coins:

- `BTC`
- `ETH`
- `SOL`
- `BNB`

## External Dependencies

- Coinbase spot price API
- RabbitMQ on `devops-data`
- history service inside Docker Compose

## Environment Variables

- `RABBITMQ_HOST`
- `RABBITMQ_USER`
- `RABBITMQ_PASS`
- `RABBITMQ_QUEUE`
- `HISTORY_HOST`

Current runtime expectations:

- `RABBITMQ_HOST=192.168.56.14`
- `HISTORY_HOST=history`

## Docker

Start the full stack:

```bash
docker compose up --build
```

Show proxy logs:

```bash
docker compose logs proxy
```

Stop the stack:

```bash
docker compose down
```

## Common Problems

### RabbitMQ Publish Errors

Likely causes:

- RabbitMQ is not running on `devops-data`
- `RABBITMQ_PASS` is wrong
- queue settings in `.env` do not match the provisioned user and queue

Check:

```bash
docker compose logs proxy
vagrant ssh devops-data -c "sudo rabbitmqctl list_users"
```

### Coinbase Fetch Errors

Likely causes:

- outbound network issue
- Coinbase API unavailable
- request timeout

Check:

```bash
docker compose logs proxy
```

### Unexpected Insert Timing

The proxy refreshes supported coins in a background loop. In the current code, `UPDATE_INTERVAL_SECONDS` is `180`, so automatic refreshes happen every 3 minutes unless a live request triggers an earlier publish.

## Notes

- prices are fetched sequentially for the background refresh loop
- whichever message is processed first can appear first in downstream storage
- this service uses Flask’s built-in server for the lab environment
