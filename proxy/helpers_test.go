package main

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"
)

func TestToFloat(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		in   interface{}
		want float64
	}{
		{name: "float64", in: 3.14, want: 3.14},
		{name: "string", in: "42.5", want: 42.5},
		{name: "json number", in: json.Number("99"), want: 99},
		{name: "invalid string", in: "abc", want: 0},
		{name: "empty string", in: "", want: 0},
		{name: "nil", in: nil, want: 0},
		{name: "unsupported type", in: true, want: 0},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := toFloat(tc.in)
			if math.Abs(got-tc.want) > 1e-9 {
				t.Fatalf("toFloat(%v) = %v, want %v", tc.in, got, tc.want)
			}
		})
	}
}

func TestParseOutcomePrices(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		raw     json.RawMessage
		wantYes float64
		wantNo  float64
	}{
		{
			name:    "direct array",
			raw:     json.RawMessage(`["0.62","0.38"]`),
			wantYes: 0.62,
			wantNo:  0.38,
		},
		{
			name:    "stringified array",
			raw:     json.RawMessage(`"[\"0.62\",\"0.38\"]"`),
			wantYes: 0.62,
			wantNo:  0.38,
		},
		{
			name:    "single element",
			raw:     json.RawMessage(`["0.75"]`),
			wantYes: 0.75,
			wantNo:  0,
		},
		{
			name:    "empty array",
			raw:     json.RawMessage(`[]`),
			wantYes: 0,
			wantNo:  0,
		},
		{
			name:    "null",
			raw:     json.RawMessage(`null`),
			wantYes: 0,
			wantNo:  0,
		},
		{
			name:    "invalid json",
			raw:     json.RawMessage(`{bad`),
			wantYes: 0,
			wantNo:  0,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			gotYes, gotNo := parseOutcomePrices(tc.raw)
			if math.Abs(gotYes-tc.wantYes) > 1e-9 || math.Abs(gotNo-tc.wantNo) > 1e-9 {
				t.Fatalf(
					"parseOutcomePrices(%s) = (%v,%v), want (%v,%v)",
					tc.raw, gotYes, gotNo, tc.wantYes, tc.wantNo,
				)
			}
		})
	}
}

func TestNormalizeMarket(t *testing.T) {
	t.Parallel()

	fetchedAt := time.Date(2026, 4, 23, 12, 0, 0, 0, time.UTC)

	t.Run("full normalization", func(t *testing.T) {
		t.Parallel()

		in := GammaMarket{
			Question:      "Will BTC exceed 100k?",
			Slug:          "btc-100k",
			OutcomePrices: json.RawMessage(`["0.62","0.38"]`),
			Volume24hr:    "1234.5",
			EndDateIso:    "2026-12-31T23:59:59Z",
			Category:      "Crypto",
		}

		got := normalizeMarket(in, fetchedAt)
		if got.Question != in.Question || got.Slug != in.Slug || got.Category != in.Category || got.EndDate != in.EndDateIso {
			t.Fatalf("normalizeMarket() basic fields mismatch: got %+v", got)
		}
		if math.Abs(got.YesPrice-0.62) > 1e-9 || math.Abs(got.NoPrice-0.38) > 1e-9 {
			t.Fatalf("normalizeMarket() prices mismatch: got yes=%v no=%v", got.YesPrice, got.NoPrice)
		}
		if math.Abs(got.Volume24h-1234.5) > 1e-9 {
			t.Fatalf("normalizeMarket() volume mismatch: got %v", got.Volume24h)
		}
		if !got.FetchedAt.Equal(fetchedAt) {
			t.Fatalf("normalizeMarket() fetchedAt mismatch: got %v want %v", got.FetchedAt, fetchedAt)
		}
	})

	t.Run("null prices become zero", func(t *testing.T) {
		t.Parallel()

		in := GammaMarket{
			OutcomePrices: json.RawMessage(`null`),
		}
		got := normalizeMarket(in, fetchedAt)
		if got.YesPrice != 0 || got.NoPrice != 0 {
			t.Fatalf("normalizeMarket() expected zero prices, got yes=%v no=%v", got.YesPrice, got.NoPrice)
		}
	})
}

func TestValidSID(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		sid  string
		want bool
	}{
		{name: "uuid like", sid: "550e8400-e29b-41d4-a716", want: true},
		{name: "min length 8", sid: "abcd1234", want: true},
		{name: "too short", sid: "abc", want: false},
		{name: "too long", sid: strings.Repeat("a", 129), want: false},
		{name: "special chars", sid: "sid!@#", want: false},
		{name: "empty", sid: "", want: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := validSID.MatchString(tc.sid)
			if got != tc.want {
				t.Fatalf("validSID.MatchString(%q) = %v, want %v", tc.sid, got, tc.want)
			}
		})
	}
}
