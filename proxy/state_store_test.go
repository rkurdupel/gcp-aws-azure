package main

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type mockStateRow struct {
	value []byte
	err   error
}

func (r mockStateRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	if len(dest) != 1 {
		return errors.New("unexpected scan destination count")
	}
	out, ok := dest[0].(*[]byte)
	if !ok {
		return errors.New("unexpected scan destination type")
	}
	if r.value == nil {
		*out = nil
		return nil
	}
	*out = append([]byte(nil), r.value...)
	return nil
}

type mockStateDB struct {
	queryRowValue []byte
	queryRowErr   error
	querySQL      string
	queryArgs     []any
	execErr       error
	execSQL       string
	execArgs      []any
}

func (m *mockStateDB) QueryRow(_ context.Context, sql string, args ...any) pgx.Row {
	m.querySQL = sql
	m.queryArgs = append([]any(nil), args...)
	return mockStateRow{value: m.queryRowValue, err: m.queryRowErr}
}

func (m *mockStateDB) Exec(_ context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	m.execSQL = sql
	m.execArgs = append([]any(nil), args...)
	var tag pgconn.CommandTag
	return tag, m.execErr
}

func TestPostgresStateStoreGetState(t *testing.T) {
	t.Parallel()

	t.Run("stored state returns bytes", func(t *testing.T) {
		t.Parallel()
		db := &mockStateDB{queryRowValue: []byte(`{"a":1}`)}
		store := &postgresStateStore{db: db}

		got, err := store.GetState(context.Background(), "abcd1234")
		if err != nil {
			t.Fatalf("GetState() error = %v", err)
		}
		if string(got) != `{"a":1}` {
			t.Fatalf("GetState() = %q, want %q", string(got), `{"a":1}`)
		}
		if db.querySQL != "SELECT runtime.session_get($1)" {
			t.Fatalf("query SQL = %q", db.querySQL)
		}
		if len(db.queryArgs) != 1 || db.queryArgs[0] != "abcd1234" {
			t.Fatalf("query args = %#v", db.queryArgs)
		}
	})

	t.Run("nil row becomes not found", func(t *testing.T) {
		t.Parallel()
		store := &postgresStateStore{db: &mockStateDB{}}

		_, err := store.GetState(context.Background(), "abcd1234")
		if !errors.Is(err, ErrStateNotFound) {
			t.Fatalf("GetState() error = %v, want ErrStateNotFound", err)
		}
	})

	t.Run("db error bubbles up", func(t *testing.T) {
		t.Parallel()
		boom := errors.New("boom")
		store := &postgresStateStore{db: &mockStateDB{queryRowErr: boom}}

		_, err := store.GetState(context.Background(), "abcd1234")
		if !errors.Is(err, boom) {
			t.Fatalf("GetState() error = %v, want %v", err, boom)
		}
	})
}

func TestPostgresStateStoreSetState(t *testing.T) {
	t.Parallel()

	t.Run("writes via runtime.session_set", func(t *testing.T) {
		t.Parallel()
		db := &mockStateDB{}
		store := &postgresStateStore{db: db}

		if err := store.SetState(context.Background(), "abcd1234", []byte(`{"a":1}`)); err != nil {
			t.Fatalf("SetState() error = %v", err)
		}
		if db.execSQL != "SELECT runtime.session_set($1, $2::jsonb, '24 hours')" {
			t.Fatalf("exec SQL = %q", db.execSQL)
		}
		if len(db.execArgs) != 2 || db.execArgs[0] != "abcd1234" {
			t.Fatalf("exec args = %#v", db.execArgs)
		}
		body, ok := db.execArgs[1].([]byte)
		if !ok || string(body) != `{"a":1}` {
			t.Fatalf("exec body arg = %#v", db.execArgs[1])
		}
	})

	t.Run("db error bubbles up", func(t *testing.T) {
		t.Parallel()
		boom := errors.New("boom")
		store := &postgresStateStore{db: &mockStateDB{execErr: boom}}

		err := store.SetState(context.Background(), "abcd1234", []byte(`{"a":1}`))
		if !errors.Is(err, boom) {
			t.Fatalf("SetState() error = %v, want %v", err, boom)
		}
	})
}
