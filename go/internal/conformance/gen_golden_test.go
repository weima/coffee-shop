package conformance

import (
	"flag"
	"os"
	"strings"
	"testing"
)

// -update rewrites the golden stream from the recorded one, so a deliberate contract
// change is a reviewable diff instead of a hand-edited fixture.
var update = flag.Bool("update", false, "rewrite golden files from recorded streams")

func TestGoldenMatchesRecorded(t *testing.T) {
	recorded, err := os.ReadFile("testdata/recorded-v05-gate.ndjson")
	if err != nil {
		t.Fatalf("read recorded: %v", err)
	}
	got := SplitLines(string(recorded))
	if *update {
		if err := os.WriteFile("testdata/golden-v05-gate.ndjson", []byte(strings.Join(got, "\n")+"\n"), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		t.Log("rewrote testdata/golden-v05-gate.ndjson")
	}
	want, err := os.ReadFile("testdata/golden-v05-gate.ndjson")
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	if err := Compare(got, SplitLines(string(want))); err != nil {
		t.Fatalf("recorded stream no longer matches the golden: %v", err)
	}
}
