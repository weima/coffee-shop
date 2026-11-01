// Command csd is the Go Coffee Shop host. It is extracted from the Odin binary at host
// start, so it is never launched by hand from a stale build.
//
// This slice speaks the contract's scaffolding only: ready, received, error, stopped.
// Dispatch, sockets and Station supervision arrive next, each proven by the conformance
// suite before it is added.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/weima/coffee-shop/go/internal/extension"
	"github.com/weima/coffee-shop/go/internal/host"
	"github.com/weima/coffee-shop/go/internal/state"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	root, err := state.Root()
	if err != nil {
		fmt.Fprintf(os.Stderr, "csd: %v\n", err)
		os.Exit(2)
	}
	// csd installs the Pi extension itself: the Odin handover no longer does it, so --impl=go
	// dispatches on a fresh state directory without any Odin setup step beforehand.
	installPath, installErr := extension.Install(root)
	if installErr != nil {
		fmt.Fprintf(os.Stderr, "csd: %v\n", installErr)
		os.Exit(2)
	}
	if installPath != "" { // silent on a no-op: the installed file already matches
		fmt.Fprintf(os.Stderr, "csd: installed the Pi extension at %s\n", installPath)
	}
	if err := host.Run(ctx, host.Options{In: os.Stdin, Out: os.Stdout, StateRoot: root}); err != nil {
		fmt.Fprintf(os.Stderr, "csd: %v\n", err)
		os.Exit(1)
	}
}
