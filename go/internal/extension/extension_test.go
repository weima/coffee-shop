package extension

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// The embedded copy must never drift from the repository's source, which the Odin binary
// embeds through HOST_EXTENSION_SOURCE.
func TestExtensionSourceMatchesTheRepositorySource(t *testing.T) {
	repoSource, err := os.ReadFile(filepath.Join("..", "..", "..", "extensions", "coffee-shop.ts"))
	if err != nil {
		t.Fatalf("read the repository source: %v", err)
	}
	embedded, err := CoffeeShop()
	if err != nil {
		t.Fatalf("extension source: %v", err)
	}
	if len(embedded) == 0 {
		t.Fatal("the embedded source must not be empty")
	}
	if !bytes.Equal(embedded, repoSource) {
		t.Fatal("go/internal/extension/coffee-shop.ts has drifted from extensions/coffee-shop.ts")
	}
}

func TestInstallWritesTheContractPathWithOwnerOnlyModes(t *testing.T) {
	root := t.TempDir()
	path, err := Install(root)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	want := filepath.Join(root, "host", "extensions", "coffee-shop.ts")
	if path != want {
		t.Fatalf("install wrote %q, want %q", path, want)
	}
	data, err := os.ReadFile(want)
	if err != nil {
		t.Fatalf("read the installed extension: %v", err)
	}
	if len(data) == 0 {
		t.Fatal("the installed extension must not be empty")
	}
	fileInfo, err := os.Stat(want)
	if err != nil {
		t.Fatalf("stat the extension: %v", err)
	}
	if got := fileInfo.Mode().Perm(); got != 0o600 {
		t.Fatalf("extension mode %o, want 600", got)
	}
	dirInfo, err := os.Stat(filepath.Dir(want))
	if err != nil {
		t.Fatalf("stat the extension directory: %v", err)
	}
	if got := dirInfo.Mode().Perm(); got != 0o700 {
		t.Fatalf("extension directory mode %o, want 700", got)
	}
}

func TestInstallIsANoOpWhenTheFileAlreadyMatches(t *testing.T) {
	root := t.TempDir()
	if _, err := Install(root); err != nil {
		t.Fatalf("first install: %v", err)
	}
	path, err := Install(root)
	if err != nil {
		t.Fatalf("second install: %v", err)
	}
	if path != "" {
		t.Fatalf("second install rewrote the file at %q, want a no-op", path)
	}
}

func TestInstallRewritesADifferingFileAndRestoresItsMode(t *testing.T) {
	root := t.TempDir()
	path, err := Install(root)
	if err != nil {
		t.Fatalf("first install: %v", err)
	}
	if err := os.WriteFile(path, []byte("stale"), 0o644); err != nil {
		t.Fatalf("write a stale extension: %v", err)
	}
	if _, err := Install(root); err != nil {
		t.Fatalf("install over a stale file: %v", err)
	}
	embedded, _ := CoffeeShop()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the installed extension: %v", err)
	}
	if !bytes.Equal(data, embedded) {
		t.Fatal("the stale extension was not replaced")
	}
	fileInfo, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat the extension: %v", err)
	}
	if got := fileInfo.Mode().Perm(); got != 0o600 {
		t.Fatalf("extension mode %o, want 600 after the rewrite", got)
	}
}
