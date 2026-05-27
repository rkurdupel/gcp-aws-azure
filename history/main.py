#!/usr/bin/env python3
"""
history-api — FastAPI service exposing historical market data.
Runs as a systemd service (history-api.service) on node-01.
Shares the same venv as consumer.py; never writes to PostgreSQL.
"""
import os
from typing import Optional

import psycopg2
import psycopg2.extras
import uvicorn
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

DATABASE_URL = os.environ["DATABASE_URL"]

app = FastAPI(title="Coin-Ops History API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)


def get_db():
    return psycopg2.connect(
        DATABASE_URL,
        cursor_factory=psycopg2.extras.RealDictCursor,
    )


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/history")
def get_history(
    limit: int = Query(default=50, ge=1, le=200),
    category: Optional[str] = Query(default=None),
):
    """Return the most recent market snapshots across all markets."""
    conn = get_db()
    try:
        with conn.cursor() as cur:
            if category:
                cur.execute(
                    """
                    SELECT id, fetched_at, question, slug,
                           yes_price, no_price, volume_24h, category, end_date
                    FROM market_snapshots
                    WHERE category ILIKE %s
                    ORDER BY fetched_at DESC
                    LIMIT %s
                    """,
                    (f"%{category}%", limit),
                )
            else:
                cur.execute(
                    """
                    SELECT id, fetched_at, question, slug,
                           yes_price, no_price, volume_24h, category, end_date
                    FROM market_snapshots
                    ORDER BY fetched_at DESC
                    LIMIT %s
                    """,
                    (limit,),
                )
            rows = cur.fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


@app.get("/history/{slug}")
def get_market_history(
    slug: str,
    limit: int = Query(default=100, ge=1, le=500),
):
    """Return time-series price history for a single market (by slug)."""
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT fetched_at, yes_price, no_price, volume_24h
                FROM market_snapshots
                WHERE slug = %s
                ORDER BY fetched_at DESC
                LIMIT %s
                """,
                (slug, limit),
            )
            rows = cur.fetchall()
        if not rows:
            raise HTTPException(status_code=404, detail="Market not found")
        return [dict(r) for r in rows]
    finally:
        conn.close()


@app.get("/prices/history/{coin}")
def get_price_history(
    coin: str,
    limit: int = Query(default=500, ge=1, le=2000),
):
    """Return time-series price history for a coin (bitcoin, ethereum, usd_uah)."""
    conn = get_db()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT fetched_at, coin, price_usd, change_24h
                FROM price_snapshots
                WHERE coin = %s
                ORDER BY fetched_at DESC
                LIMIT %s
                """,
                (coin, limit),
            )
            rows = cur.fetchall()
        if not rows:
            raise HTTPException(status_code=404, detail="No price data for this coin")
        return [dict(r) for r in rows]
    finally:
        conn.close()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    uvicorn.run(app, host="0.0.0.0", port=port)
