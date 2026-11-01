// Package extension carries the Pi extension a Station launches with. The Odin binary
// embeds the source as HOST_EXTENSION_SOURCE; the Go host's copy sits next to this
// package and a test pins it to the repository's extensions/coffee-shop.ts, so the two
// copies cannot drift apart silently.
package extension

import (
	_ "embed"

	"os"
	"path/filepath"

	"github.com/weima/coffee-shop/go/internal/state"
)

//go:embed coffee-shop.ts
var coffeeShop []byte

// CoffeeShop returns the Pi extension source this binary was built with.
func CoffeeShop() ([]byte, error) {
	return coffeeShop, nil
}

// Install places the Pi extension at <root>/host/extensions/coffee-shop.ts. The install
// is idempotent: an existing file with identical bytes is left untouched, and the return
// is "" so callers can stay silent about a no-op.
func Install(root string) (string, error) {
	dir := filepath.Join(state.HostDir(root), "extensions")
	if err := state.EnsureDir(dir, true); err != nil {
		return "", err
	}
	data, err := CoffeeShop()
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, "coffee-shop.ts")
	if existing, readErr := os.ReadFile(path); readErr == nil && string(existing) == string(data) {
		return "", nil
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return "", err
	}
	// WriteFile's perm applies only on create; a differing file keeps whatever mode an
	// older install left, so set it here.
	if err := os.Chmod(path, 0o600); err != nil {
		return "", err
	}
	return path, nil
}
