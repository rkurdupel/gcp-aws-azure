package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCorsMiddlewareGETSetsHeadersAndCallsNext(t *testing.T) {
	t.Parallel()

	called := false
	h := corsMiddleware(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	})

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()
	h(rr, req)

	if !called {
		t.Fatal("expected wrapped handler to be called")
	}
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusOK)
	}
	if got := rr.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("Access-Control-Allow-Origin = %q, want *", got)
	}
	if got := rr.Header().Get("Access-Control-Allow-Methods"); got != "GET, OPTIONS" {
		t.Fatalf("Access-Control-Allow-Methods = %q, want %q", got, "GET, OPTIONS")
	}
	assertNoStoreHeaders(t, rr.Header())
}

func TestCorsMiddlewareOptionsReturnsNoContent(t *testing.T) {
	t.Parallel()

	called := false
	h := corsMiddleware(func(w http.ResponseWriter, r *http.Request) {
		called = true
	})

	req := httptest.NewRequest(http.MethodOptions, "/health", nil)
	rr := httptest.NewRecorder()
	h(rr, req)

	if called {
		t.Fatal("expected wrapped handler not to be called for OPTIONS")
	}
	if rr.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d", rr.Code, http.StatusNoContent)
	}
	assertNoStoreHeaders(t, rr.Header())
}

func TestCorsMiddlewareWithPostAllowsPostAndOptions(t *testing.T) {
	t.Parallel()

	t.Run("options has post in allow methods", func(t *testing.T) {
		t.Parallel()
		h := corsMiddlewareWithPost(func(w http.ResponseWriter, r *http.Request) {})
		req := httptest.NewRequest(http.MethodOptions, "/state", nil)
		rr := httptest.NewRecorder()
		h(rr, req)

		if rr.Code != http.StatusNoContent {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusNoContent)
		}
		if got := rr.Header().Get("Access-Control-Allow-Methods"); got != "GET, POST, OPTIONS" {
			t.Fatalf("Access-Control-Allow-Methods = %q, want %q", got, "GET, POST, OPTIONS")
		}
	})

	t.Run("post calls wrapped handler", func(t *testing.T) {
		t.Parallel()
		called := false
		h := corsMiddlewareWithPost(func(w http.ResponseWriter, r *http.Request) {
			called = true
			w.WriteHeader(http.StatusCreated)
		})
		req := httptest.NewRequest(http.MethodPost, "/state?sid=abcd1234", nil)
		rr := httptest.NewRecorder()
		h(rr, req)

		if !called {
			t.Fatal("expected wrapped handler to be called for POST")
		}
		if rr.Code != http.StatusCreated {
			t.Fatalf("status = %d, want %d", rr.Code, http.StatusCreated)
		}
	})
}

func TestSetNoStoreHeaders(t *testing.T) {
	t.Parallel()

	rr := httptest.NewRecorder()
	setNoStoreHeaders(rr)
	assertNoStoreHeaders(t, rr.Header())
}

func assertNoStoreHeaders(t *testing.T, h http.Header) {
	t.Helper()
	if got := h.Get("Cache-Control"); got != "no-store, no-cache, must-revalidate, proxy-revalidate" {
		t.Fatalf("Cache-Control = %q", got)
	}
	if got := h.Get("Pragma"); got != "no-cache" {
		t.Fatalf("Pragma = %q, want no-cache", got)
	}
	if got := h.Get("Expires"); got != "0" {
		t.Fatalf("Expires = %q, want 0", got)
	}
}
