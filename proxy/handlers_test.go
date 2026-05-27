package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type mockStateStore struct {
	data   map[string][]byte
	getErr error
	setErr error
}

func (m *mockStateStore) GetState(_ context.Context, sid string) ([]byte, error) {
	if m.getErr != nil {
		return nil, m.getErr
	}
	v, ok := m.data[sid]
	if !ok {
		return nil, ErrStateNotFound
	}
	return append([]byte(nil), v...), nil
}

func (m *mockStateStore) SetState(_ context.Context, sid string, value []byte) error {
	if m.setErr != nil {
		return m.setErr
	}
	if m.data == nil {
		m.data = make(map[string][]byte)
	}
	m.data[sid] = append([]byte(nil), value...)
	return nil
}

func newTestServer() *Server {
	return &Server{
		backend: "external",
		state:   &mockStateStore{data: make(map[string][]byte)},
	}
}

func TestHandleHealth(t *testing.T) {
	t.Parallel()
	srv := newTestServer()

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()
	srv.handleHealth(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
	}
	if strings.TrimSpace(rr.Body.String()) != `{"runtime_backend":"external","status":"ok"}` {
		t.Fatalf("body = %s", rr.Body.String())
	}
}

func TestHandleWhales(t *testing.T) {
	t.Parallel()

	t.Run("returns cached whales", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		srv.cache.Lock()
		srv.cache.whales = []Whale{{Pseudonym: "A", Address: "0x1", Pnl: 1.2, Volume: 3.4, Rank: 1}}
		srv.cache.Unlock()

		req := httptest.NewRequest(http.MethodGet, "/whales", nil)
		rr := httptest.NewRecorder()
		srv.handleWhales(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
		}
		if !strings.Contains(rr.Body.String(), `"pseudonym":"A"`) {
			t.Fatalf("unexpected body: %s", rr.Body.String())
		}
	})

	t.Run("empty cache returns null", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		req := httptest.NewRequest(http.MethodGet, "/whales", nil)
		rr := httptest.NewRecorder()
		srv.handleWhales(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
		}
		if strings.TrimSpace(rr.Body.String()) != "null" {
			t.Fatalf("body = %q, want null", strings.TrimSpace(rr.Body.String()))
		}
	})
}

func TestHandlePrices(t *testing.T) {
	t.Parallel()
	srv := newTestServer()
	now := time.Now().UTC()

	srv.cache.Lock()
	srv.cache.prices = Prices{
		BtcUsd:       1,
		EthUsd:       2,
		Btc24hChange: 3,
		Eth24hChange: 4,
		UsdUah:       5,
		FetchedAt:    now,
	}
	srv.cache.Unlock()

	req := httptest.NewRequest(http.MethodGet, "/prices", nil)
	rr := httptest.NewRecorder()
	srv.handlePrices(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
	}
	if !strings.Contains(rr.Body.String(), `"btc_usd":1`) || !strings.Contains(rr.Body.String(), `"usd_uah":5`) {
		t.Fatalf("unexpected body: %s", rr.Body.String())
	}
}

func TestHandleCurrent(t *testing.T) {
	t.Parallel()

	t.Run("returns cached markets", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		srv.cache.Lock()
		srv.cache.markets = []MarketSnapshot{{Slug: "m1", Question: "Q1"}}
		srv.cache.Unlock()

		req := httptest.NewRequest(http.MethodGet, "/current", nil)
		rr := httptest.NewRecorder()
		srv.handleCurrent(rr, req)

		if rr.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
		}
		if !strings.Contains(rr.Body.String(), `"slug":"m1"`) {
			t.Fatalf("unexpected body: %s", rr.Body.String())
		}
	})

	t.Run("empty cache and fetch failure returns 502", func(t *testing.T) {
		// Not parallel: patches the package-level httpClient.
		srv := newTestServer()

		origClient := httpClient
		httpClient = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return nil, errors.New("simulated network failure")
		})}
		t.Cleanup(func() { httpClient = origClient })

		req := httptest.NewRequest(http.MethodGet, "/current", nil)
		rr := httptest.NewRecorder()
		srv.handleCurrent(rr, req)

		if rr.Code != http.StatusBadGateway {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusBadGateway)
		}
	})
}

func TestHandleStateRouting(t *testing.T) {
	t.Parallel()

	t.Run("get routes to get handler", func(t *testing.T) {
		t.Parallel()
		req := httptest.NewRequest(http.MethodGet, "/state?sid=abcd1234", nil)
		rr := httptest.NewRecorder()
		newTestServer().handleState(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
		}
		if strings.TrimSpace(rr.Body.String()) != "{}" {
			t.Fatalf("unexpected body: %s", rr.Body.String())
		}
	})

	t.Run("post routes to post handler", func(t *testing.T) {
		t.Parallel()
		req := httptest.NewRequest(http.MethodPost, "/state?sid=abcd1234", strings.NewReader(`{"x":1}`))
		rr := httptest.NewRecorder()
		newTestServer().handleState(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
		}
	})

	t.Run("put returns 405", func(t *testing.T) {
		t.Parallel()
		req := httptest.NewRequest(http.MethodPut, "/state?sid=abcd1234", nil)
		rr := httptest.NewRecorder()
		newTestServer().handleState(rr, req)
		if rr.Code != http.StatusMethodNotAllowed {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusMethodNotAllowed)
		}
	})

	t.Run("delete returns 405", func(t *testing.T) {
		t.Parallel()
		req := httptest.NewRequest(http.MethodDelete, "/state?sid=abcd1234", nil)
		rr := httptest.NewRecorder()
		newTestServer().handleState(rr, req)
		if rr.Code != http.StatusMethodNotAllowed {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusMethodNotAllowed)
		}
	})
}

func TestHandleGetState(t *testing.T) {
	t.Parallel()

	t.Run("missing sid returns 400", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		req := httptest.NewRequest(http.MethodGet, "/state", nil)
		rr := httptest.NewRecorder()
		srv.handleGetState(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusBadRequest)
		}
	})

	t.Run("invalid sid returns 400", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		req := httptest.NewRequest(http.MethodGet, "/state?sid=bad!sid", nil)
		rr := httptest.NewRecorder()
		srv.handleGetState(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusBadRequest)
		}
	})

	t.Run("state not found returns empty object", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		req := httptest.NewRequest(http.MethodGet, "/state?sid=abcd1234", nil)
		rr := httptest.NewRecorder()
		srv.handleGetState(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
		}
		if strings.TrimSpace(rr.Body.String()) != "{}" {
			t.Fatalf("body = %q, want {}", strings.TrimSpace(rr.Body.String()))
		}
	})

	t.Run("stored state returns json", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		store := srv.state.(*mockStateStore)
		store.data["abcd1234"] = []byte(`{"a":1}`)
		req := httptest.NewRequest(http.MethodGet, "/state?sid=abcd1234", nil)
		rr := httptest.NewRecorder()
		srv.handleGetState(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
		}
		if strings.TrimSpace(rr.Body.String()) != `{"a":1}` {
			t.Fatalf("body = %q", strings.TrimSpace(rr.Body.String()))
		}
	})

	t.Run("store error returns 503", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		srv.state = &mockStateStore{getErr: errors.New("boom")}
		req := httptest.NewRequest(http.MethodGet, "/state?sid=abcd1234", nil)
		rr := httptest.NewRecorder()
		srv.handleGetState(rr, req)
		if rr.Code != http.StatusServiceUnavailable {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusServiceUnavailable)
		}
	})
}

func TestHandlePostState(t *testing.T) {
	t.Parallel()

	t.Run("missing sid returns 400", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		req := httptest.NewRequest(http.MethodPost, "/state", strings.NewReader(`{"a":1}`))
		rr := httptest.NewRecorder()
		srv.handlePostState(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusBadRequest)
		}
	})

	t.Run("invalid sid returns 400", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		req := httptest.NewRequest(http.MethodPost, "/state?sid=bad!sid", strings.NewReader(`{"a":1}`))
		rr := httptest.NewRecorder()
		srv.handlePostState(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusBadRequest)
		}
	})

	t.Run("invalid json body returns 400", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		req := httptest.NewRequest(http.MethodPost, "/state?sid=abcd1234", strings.NewReader(`{bad`))
		rr := httptest.NewRecorder()
		srv.handlePostState(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusBadRequest)
		}
	})

	t.Run("valid json stores value and returns 200", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		req := httptest.NewRequest(http.MethodPost, "/state?sid=abcd1234", strings.NewReader(`{"a":1}`))
		rr := httptest.NewRecorder()
		srv.handlePostState(rr, req)
		if rr.Code != http.StatusOK {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
		}

		store := srv.state.(*mockStateStore)
		if got := string(store.data["abcd1234"]); got != `{"a":1}` {
			t.Fatalf("stored value = %q, want %q", got, `{"a":1}`)
		}
	})

	t.Run("oversized body is limited and fails json validation", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		large := `{"x":"` + strings.Repeat("a", 5000) + `"}`
		req := httptest.NewRequest(http.MethodPost, "/state?sid=abcd1234", strings.NewReader(large))
		rr := httptest.NewRecorder()
		srv.handlePostState(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusBadRequest)
		}
	})

	t.Run("store error returns 503", func(t *testing.T) {
		t.Parallel()
		srv := newTestServer()
		srv.state = &mockStateStore{setErr: errors.New("boom")}
		req := httptest.NewRequest(http.MethodPost, "/state?sid=abcd1234", strings.NewReader(`{"a":1}`))
		rr := httptest.NewRecorder()
		srv.handlePostState(rr, req)
		if rr.Code != http.StatusServiceUnavailable {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusServiceUnavailable)
		}
	})
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func TestFetchJSONUsesConfiguredTransport(t *testing.T) {
	// Not parallel: patches the package-level httpClient.
	client := &http.Client{
		Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusOK,
				Body:       io.NopCloser(strings.NewReader(`[]`)),
				Header:     make(http.Header),
			}, nil
		}),
	}

	orig := httpClient
	httpClient = client
	t.Cleanup(func() { httpClient = orig })

	var out []json.RawMessage
	if err := fetchJSON("http://example.invalid", &out); err != nil {
		t.Fatalf("fetchJSON returned error: %v", err)
	}
}
