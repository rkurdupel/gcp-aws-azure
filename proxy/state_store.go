package main

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/redis/go-redis/v9"
)

// StateStore abstracts session-state persistence across runtime backends.
type StateStore interface {
	GetState(ctx context.Context, sid string) ([]byte, error)
	SetState(ctx context.Context, sid string, value []byte) error
}

var ErrStateNotFound = errors.New("state not found")

type stateDB interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

type redisStateStore struct {
	c *redis.Client
}

func (r *redisStateStore) GetState(ctx context.Context, sid string) ([]byte, error) {
	val, err := r.c.Get(ctx, "session:"+sid).Result()
	if err == redis.Nil {
		return nil, ErrStateNotFound
	}
	if err != nil {
		return nil, err
	}
	return []byte(val), nil
}

func (r *redisStateStore) SetState(ctx context.Context, sid string, value []byte) error {
	return r.c.Set(ctx, "session:"+sid, string(value), 24*time.Hour).Err()
}

type postgresStateStore struct {
	db stateDB
}

func (p *postgresStateStore) GetState(ctx context.Context, sid string) ([]byte, error) {
	var val []byte
	err := p.db.QueryRow(ctx, "SELECT runtime.session_get($1)", sid).Scan(&val)
	if err != nil {
		return nil, err
	}
	if val == nil {
		return nil, ErrStateNotFound
	}
	return val, nil
}

func (p *postgresStateStore) SetState(ctx context.Context, sid string, value []byte) error {
	_, err := p.db.Exec(ctx, "SELECT runtime.session_set($1, $2::jsonb, '24 hours')", sid, value)
	return err
}
