package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// The passkey response RPC must reject malformed input up front (-32602)
// before anything reaches the wire: missing param, non-JSON payload, and
// assertions missing required WebAuthn fields.
func TestHandlePasskeyResponseValidation(t *testing.T) {
	b := &bridge{}
	cases := map[string]string{
		"missing params":       ``,
		"missing response":     `{}`,
		"payload not json":     `{"response_json":"not json"}`,
		"incomplete assertion": `{"response_json":"{\"id\":\"\",\"rawId\":\"\",\"response\":{}}"}`,
	}
	for name, params := range cases {
		var raw json.RawMessage
		if params != "" {
			raw = json.RawMessage(params)
		}
		result, rpcErr := b.handlePasskeyResponse(raw)
		if result != nil || rpcErr == nil || rpcErr.Code != -32602 {
			t.Errorf("%s: expected -32602 refusal, got result=%v err=%+v", name, result, rpcErr)
		}
	}
}

// Helper-written media paths must never traverse or hide: no separators,
// no leading dots, bounded length.
func TestSanitizeFileName(t *testing.T) {
	cases := map[string]string{
		"photo.jpg": "photo.jpg",
		// Separators are replaced and leading dots stripped, so the result
		// can never traverse out of the media directory.
		"../../etc/passwd":   "_.._etc_passwd",
		".hidden":            "hidden",
		"weird name (1).png": "weird_name__1_.png",
		"a/b\\c:d.pdf":       "a_b_c_d.pdf",
	}
	for input, want := range cases {
		if got := sanitizeFileName(input); got != want {
			t.Errorf("sanitizeFileName(%q) = %q, want %q", input, got, want)
		}
	}

	long := strings.Repeat("x", 200) + ".jpg"
	sanitized := sanitizeFileName(long)
	if len(sanitized) != 120 {
		t.Errorf("long name should truncate to 120 chars, got %d", len(sanitized))
	}
	if !strings.HasSuffix(sanitized, ".jpg") {
		t.Errorf("truncation must keep the tail (extension), got %q", sanitized)
	}
}

func TestExtensionForMime(t *testing.T) {
	cases := []struct {
		mimetype  string
		mediaType string
		want      string
	}{
		{"image/jpeg", "image", ".jpg"},
		{"image/jpeg; codecs=whatever", "image", ".jpg"},
		{"video/mp4", "video", ".mp4"},
		{"audio/ogg", "audio", ".ogg"},
		{"application/pdf", "document", ".pdf"},
		// Unknown MIME falls back by media class.
		{"application/x-unknown-thing", "image", ".jpg"},
	}
	for _, c := range cases {
		if got := extensionForMime(c.mimetype, c.mediaType); got != c.want {
			t.Errorf("extensionForMime(%q, %q) = %q, want %q", c.mimetype, c.mediaType, got, c.want)
		}
	}
}
