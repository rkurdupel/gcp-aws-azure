# UI Service

## Responsibility

The UI service is a Flask web application that:

- renders the main dashboard
- renders the history page
- requests live prices from the proxy service
- requests chart and table data from the history service
- stores session data in Redis

## Runtime

- language: Python 3
- framework: Flask
- container port: `5000`
- Docker host access: `http://localhost:5000`

## Endpoints

- `GET /` - main dashboard
- `GET /history` - historical records page with filters
- `GET /api/chart-data` - chart data for frontend updates

## Dependencies

- Redis on `devops-data`
- proxy service inside Docker Compose
- history service inside Docker Compose

## Environment Variables

- `REDIS_HOST`
- `REDIS_PORT`
- `REDIS_PASSWORD`
- `PROXY_HOST`
- `HISTORY_HOST`
- `SECRET_KEY`

Current runtime expectations:

- `PROXY_HOST=proxy`
- `HISTORY_HOST=history`
- `REDIS_HOST=192.168.56.14`

## Docker

Start the full application stack:

```bash
docker compose up --build
```

Show UI logs:

```bash
docker compose logs ui
```

Stop the stack:

```bash
docker compose down
```

## Common Problems

### HTTP 500 On `/`

Likely causes:

- Redis is unavailable
- proxy is unavailable
- history is unavailable
- `SECRET_KEY` or Redis settings are wrong in `.env`

Check:

```bash
docker compose logs ui
```

### No Live Price

Likely causes:

- proxy container is down
- `PROXY_HOST` is wrong

Check:

```bash
docker compose logs proxy
```

### No Chart Or History Data

Likely causes:

- history container is down
- `HISTORY_HOST` is wrong
- history cannot reach PostgreSQL or RabbitMQ on `devops-data`

Check:

```bash
docker compose logs history
```

## Notes

- the Flask app reads `SECRET_KEY` from the environment
- the UI expects Docker DNS to resolve `proxy` and `history`
- this service uses Flask’s built-in server, which is acceptable for this lab setup
