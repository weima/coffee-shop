// Command measure drives the v0.6 host measurement (Wave-3 item 7).
//
// It dispatches five Shots through a running csd, records the event stream, derives
// per-Shot wall clocks from `at`, samples the host process's resource peaks, writes a
// comparison-ready report, and prints machine facts. One binary replaces the shell
// driver so the logic lives where the evidence lands.
//
// Usage:
//
//	go run ./cmd/measure [-out DIR] [-shots N] [-hold taste] [-csd PATH] [-state DIR]
//
// The tool refuses to run when `herdr` is on PATH, because a measurement of the Go host
// is not a measurement of Go plus Herdr.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// TasteHold matches the sustained v0.6 measurement plan.
const TasteHold = "sleep 30"

type config struct {
	out   string
	shots int
	csd   string
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "measure: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	cfg := config{}
	flag.StringVar(&cfg.out, "out", "", "output directory (required)")
	flag.IntVar(&cfg.shots, "shots", 5, "number of Shots")
	flag.StringVar(&cfg.csd, "csd", "", "path to the csd binary (defaults to go run ./cmd/csd)")
	flag.Parse()
	if cfg.out == "" {
		return fmt.Errorf("-out is required")
	}
	if err := os.MkdirAll(cfg.out, 0o700); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}

	if err := checkTools(); err != nil {
		return err
	}

	wd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("resolve working directory: %w", err)
	}
	repo, err := findRepoRoot(wd)
	if err != nil {
		return err
	}
	cfg.out = abs(cfg.out)
	repo = abs(repo)

	if err := writeMachineFacts(filepath.Join(cfg.out, "machine.txt")); err != nil {
		// Not fatal: the report is weaker without them, but the run still counts.
		fmt.Fprintf(os.Stderr, "machine facts: %v\n", err)
	}

	beans, err := makeBeans(filepath.Join(cfg.out, "beans"))
	if err != nil {
		return fmt.Errorf("prepare beans: %w", err)
	}

	statePath := filepath.Join(cfg.out, "state")
	extensions := filepath.Join(statePath, "host", "extensions")
	if err := os.MkdirAll(extensions, 0o700); err != nil {
		return fmt.Errorf("create extensions directory: %w", err)
	}
	src, err := os.ReadFile(filepath.Join(repo, "extensions", "coffee-shop.ts"))
	if err == nil {
		_ = os.WriteFile(filepath.Join(extensions, "coffee-shop.ts"), src, 0o600)
	}

	// --- start the host -------------------------------------------------------------
	stdin, hostCmd, err := startHost(repo, statePath, beans, cfg.out)
	if err != nil {
		return err
	}
	defer func() {
		_ = hostCmd.Process.Kill()
		_ = hostCmd.Wait()
	}()

	// Sample the host process's resource peaks every second.
	stop := make(chan struct{})
	var samplesWG sync.WaitGroup
	samplesWG.Add(1)
	go sampleHost(hostCmd, filepath.Join(cfg.out, "host-peaks.csv"), stop, &samplesWG)

	// Wait for the request socket to appear, then dispatch.
	sock := filepath.Join(statePath, "host", "requests.sock")
	if err := waitForSocket(sock, 30*time.Second); err != nil {
		return err
	}
	if err := dispatch(stdin, beans, cfg.shots, TasteHold); err != nil {
		return fmt.Errorf("dispatch: %w", err)
	}

	// --- wait for all Shots to go terminal ------------------------------------------
	deadline := time.Now().Add(8 * time.Minute)
	for time.Now().Before(deadline) {
		events := readLines(filepath.Join(cfg.out, "events.jsonl"))
		terminal := 0
		for _, line := range events {
			e := parse(line)
			if e.Type == "station_report" && measurementShotTerminal(e.Kind) {
				terminal++
			}
		}
		if terminal >= cfg.shots {
			break
		}
		time.Sleep(time.Second)
	}

	events := readLines(filepath.Join(cfg.out, "events.jsonl"))
	terminal := 0
	for _, line := range events {
		e := parse(line)
		if e.Type == "station_report" && measurementShotTerminal(e.Kind) {
			terminal++
		}
	}
	if terminal < cfg.shots {
		return fmt.Errorf("only %d of %d Shots terminal; keeping artifacts in %s", terminal, cfg.shots, cfg.out)
	}
	fmt.Printf("all %d Shots terminal\n", cfg.shots)

	// --- shutdown -------------------------------------------------------------------
	if _, err := io.WriteString(stdin, `{"type":"shutdown","request_id":"stop-measure"}`+"\n"); err != nil {
		fmt.Fprintf(os.Stderr, "shutdown: %v\n", err)
	}
	_ = stdin.Close()
	waitCh := make(chan error, 1)
	go func() { waitCh <- hostCmd.Wait() }()
	select {
	case <-waitCh:
	case <-time.After(15 * time.Second):
		fmt.Fprintln(os.Stderr, "host did not exit within 15s of shutdown; killing")
		_ = hostCmd.Process.Kill()
		<-waitCh
	}
	close(stop)
	samplesWG.Wait()

	// --- derive and write the report -------------------------------------------------
	rows, err := writePerShot(cfg.out, events)
	if err != nil {
		return fmt.Errorf("per-Shot derivation: %w", err)
	}
	peak, err := summarisePeaks(filepath.Join(cfg.out, "host-peaks.csv"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "peaks: %v\n", err)
	}
	if err := writeReport(cfg.out, rows, peak); err != nil {
		return fmt.Errorf("write report: %w", err)
	}

	fmt.Printf("\n== artifacts ==\n%s\n", listDir(cfg.out))
	fmt.Printf("\n== per-Shot wall clock ==\n%s\n", rows.render())
	fmt.Printf("\n== next steps ==\n"+
		"1. copy host-peaks.csv peaks and machine.txt into PLAN.md\n"+
		"2. repeat on WSL2 with the project inside the Linux filesystem\n\n"+
		"Output directory: %s\n", cfg.out)
	return nil
}

// --- helpers -------------------------------------------------------------------------

func findRepoRoot(start string) (string, error) {
	current, err := filepath.Abs(start)
	if err != nil {
		return "", fmt.Errorf("resolve repository search path: %w", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(current, "go", "go.mod")); err == nil {
			return current, nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("run from inside the repository; no go/go.mod found above %s", start)
		}
		current = parent
	}
}

func checkTools() error {
	for _, tool := range []string{"go", "pi"} {
		if _, err := exec.LookPath(tool); err != nil {
			return fmt.Errorf("%s is not on PATH; the measurement needs it (%v)", tool, err)
		}
	}
	if _, err := exec.LookPath("herdr"); err == nil {
		return fmt.Errorf("herdr IS on PATH; re-run from a shell without it, or the run is not headless")
	}
	return nil
}

func abs(p string) string {
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	wd, _ := os.Getwd()
	return filepath.Join(wd, p)
}

// makeBeans creates a tiny scratch repository in the output directory, so nothing in the
// caller's own tree is touched.
func makeBeans(out string) (string, error) {
	beans := filepath.Join(out, "beans")
	if err := os.MkdirAll(beans, 0o700); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(beans, "README.md"), []byte("# beans\n\nmeasurement scratch\n"), 0o600); err != nil {
		return "", err
	}
	cmd := exec.Command("git", "-C", beans, "init", "-q")
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("git init: %w", err)
	}
	for _, args := range [][]string{
		{"add", "-A"},
		{"-c", "user.name=m", "-c", "user.email=m@e", "commit", "-q", "--allow-empty", "-m", "init"},
	} {
		c := exec.Command("git", append([]string{"-C", beans}, args...)...)
		if err := c.Run(); err != nil {
			return "", fmt.Errorf("git %v: %w", args[0], err)
		}
	}
	return beans, nil
}

// startHost launches csd as a subprocess and returns a stdin writer for it.
func startHost(repo, statePath, beans, out string) (io.WriteCloser, *exec.Cmd, error) {
	cs_cli := filepath.Join(out, "coffee-shop-cli")
	cliScript := fmt.Sprintf("#!/bin/sh\nexec %s run %s -- \"$@\"\n", shellQuote(lookPath("odin")), shellQuote(filepath.Join(repo, "src")))
	if err := os.WriteFile(cs_cli, []byte(cliScript), 0o700); err != nil {
		return nil, nil, fmt.Errorf("write Odin CLI wrapper: %w", err)
	}
	cs_agent := filepath.Join(out, "agent.sh")
	if err := os.WriteFile(cs_agent, []byte(measurementAgentScript()), 0o700); err != nil {
		return nil, nil, fmt.Errorf("write agent: %w", err)
	}

	cmd := exec.Command("go", "run", "./cmd/csd")
	cmd.Dir = filepath.Join(repo, "go")
	cmd.Env = append(os.Environ(),
		"CS_STATE_DIR="+statePath,
		"CS_CLI="+cs_cli,
		"CS_AGENT="+cs_agent,
	)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, nil, err
	}
	cmdStdout, err := os.Create(filepath.Join(out, "events.jsonl"))
	if err != nil {
		return nil, nil, err
	}
	stderrF, err := os.Create(filepath.Join(out, "host.err"))
	if err != nil {
		_ = cmdStdout.Close()
		return nil, nil, err
	}
	cmd.Stdout = cmdStdout
	cmd.Stderr = stderrF
	// Keep handles so the goroutine that samples resources can stat them later.
	if err := cmd.Start(); err != nil {
		return nil, nil, fmt.Errorf("start csd: %w", err)
	}
	fmt.Printf("csd started (pid %d)\n", cmd.Process.Pid)
	snap := fmt.Sprintf("%d", cmd.Process.Pid)
	_ = os.WriteFile(filepath.Join(out, "host.pid"), []byte(snap), 0o600)
	// Close the parent's copy so we do not hold the child's output open after it exits.
	// The cmd.Stdout/Stderr fields keep the file handles we need.
	go func() {
		defer func() {
			_ = cmdStdout.Close()
			_ = stderrF.Close()
		}()
		_ = cmd.Wait()
	}()
	return stdin, cmd, nil
}

func lookPath(name string) string {
	path, err := exec.LookPath(name)
	if err != nil {
		return name
	}
	return path
}

func shellQuote(value string) string {
	if value == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func dispatch(stdin io.Writer, beans string, shots int, hold string) error {
	var shotJSON []string
	for i := 0; i < shots; i++ {
		shotJSON = append(shotJSON, fmt.Sprintf(`{"id":"s%d","prompt":"measured","taste":%q,"message":"measured"}`, i+1, hold))
	}
	request := fmt.Sprintf(`{"type":"dispatch","request_id":"measure-1","repo":%q,"recipe":{"shots":[%s]}}`+"\n",
		beans, strings.Join(shotJSON, ","))
	if _, err := io.WriteString(stdin, request); err != nil {
		return err
	}
	return nil
}

func waitForSocket(path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("request socket never appeared at %s", path)
}

// --- event stream helpers -----------------------------------------------------------

type Event struct {
	Type        string `json:"type"`
	RequestID   string `json:"request_id"`
	ShotID      string `json:"shot_id,omitempty"`
	Kind        string `json:"kind,omitempty"`
	Description string `json:"description,omitempty"`
	At          string `json:"at"`
}

func parse(line string) Event {
	var e Event
	// Decode leniently: unknown fields are ignored, missing fields keep zero values.
	_ = json.Unmarshal([]byte(line), &e)
	return e
}

func terminalKind(kind string) bool {
	switch kind {
	case "pulled", "taste_passed", "taste_failed", "incomplete", "session_failed", "agent_exited":
		return true
	}
	return false
}

// A Taste hold completes at turn_done on the host's normal interactive path.
func measurementShotTerminal(kind string) bool {
	// Wait for the post-turn Taste result, not turn_done or agent_exited.
	switch kind {
	case "pulled", "taste_passed", "taste_failed", "incomplete", "session_failed":
		return true
	}
	return false
}

func measurementAgentScript() string {
	return `#!/bin/sh
while IFS= read -r line; do
  case "$line" in
  *get_session_stats*) continue ;;
  esac
  printf '%s\n' '{"type":"message_start","message":{"role":"assistant"}}'
  printf '%s\n' '{"type":"text_delta","text":"measured"}'
  printf '%s\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"measured"}]}}'
  printf '%s\n' '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"measured"}]}]}'
done
`
}

func readLines(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
}

// parseStamp parses the `at` field's fixed shape.
func parseStamp(at string) (time.Time, error) {
	return time.Parse("2006-01-02T15:04:05.000Z", at)
}

// --- per-Shot wall clock -------------------------------------------------------------

type Rows []struct {
	Shot string
	From time.Time
	To   time.Time
	Kind string
}

func writePerShot(outDir string, events []string) (Rows, error) {
	rows := Rows{}
	starts := map[string]time.Time{}
	ends := map[string]time.Time{}
	kinds := map[string]string{}
	for _, line := range events {
		if line == "" {
			continue
		}
		e := parse(line)
		t, err := parseStamp(e.At)
		if err != nil {
			return nil, fmt.Errorf("event %q has a malformed timestamp: %w", e.At, err)
		}
		if e.Type == "session_started" && e.ShotID != "" {
			if _, ok := starts[e.ShotID]; !ok {
				starts[e.ShotID] = t
				kinds[e.ShotID] = "started"
			}
		}
		if e.Type == "station_report" && measurementShotTerminal(e.Kind) && e.ShotID != "" {
			if prev, ok := ends[e.ShotID]; !ok || t.After(prev) {
				ends[e.ShotID] = t
				kinds[e.ShotID] = e.Kind
			}
		}
	}
	keys := make([]string, 0, len(starts))
	for k := range starts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, shot := range keys {
		from, okFrom := starts[shot]
		to, okTo := ends[shot]
		if !okFrom || !okTo {
			continue
		}
		rows = append(rows, struct {
			Shot string
			From time.Time
			To   time.Time
			Kind string
		}{Shot: shot, From: from, To: to, Kind: kinds[shot]})
	}

	var csv strings.Builder
	csv.WriteString("shot,started_at,ended_at,terminal_kind,seconds\n")
	for _, r := range rows {
		fmt.Fprintf(&csv, "%s,%s,%s,%s,%.3f\n",
			r.Shot, r.From.UTC().Format(time.RFC3339Nano), r.To.UTC().Format(time.RFC3339Nano), r.Kind, r.To.Sub(r.From).Seconds())
	}
	if err := os.WriteFile(filepath.Join(outDir, "per-shot.csv"), []byte(csv.String()), 0o600); err != nil {
		return rows, err
	}
	return rows, nil
}

func (r Rows) render() string {
	var b strings.Builder
	b.WriteString("| shot | wall clock |\n|---|---|\n")
	total := time.Duration(0)
	var first, last time.Time
	for _, row := range r {
		d := row.To.Sub(row.From)
		fmt.Fprintf(&b, "| %s (%s) | %.3f s |\n", row.Shot, row.Kind, d.Seconds())
		total += d
		if first.IsZero() || row.From.Before(first) {
			first = row.From
		}
		if last.IsZero() || row.To.After(last) {
			last = row.To
		}
	}
	span := last.Sub(first)
	fmt.Fprintf(&b, "| whole run (span) | %.3f s |\n", span.Seconds())
	fmt.Fprintf(&b, "| sum of per-Shot wall clocks | %.3f s |\n", total.Seconds())
	if span.Seconds() > total.Seconds() {
		fmt.Fprintf(&b, "| overlap (span minus sum) | %.3f s |\n", (span - total).Seconds())
	}
	return b.String()
}

// --- resource peaks ------------------------------------------------------------------

func sampleHost(cmd *exec.Cmd, path string, stop <-chan struct{}, wg *sync.WaitGroup) {
	defer wg.Done()
	file, err := os.Create(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "sample host: %v\n", err)
		return
	}
	defer func() { _ = file.Close() }()

	// One sample per second of the go-run tree's RSS/CPU. `ps` works on both macOS and
	// Linux for pid-based resource lookups.
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		select {
		case <-stop:
			return
		case <-tick.C:
			s := sampleTree(cmd.Process.Pid)
			if s != "" {
				fmt.Fprintln(file, s)
			}
		}
	}
}

func sampleTree(pid int) string {
	var peak string
	// Collect the tree rooted at pid via ps. On Linux, RSS comes from /proc, on macOS
	// ps handles it.
	cmd := exec.Command("sh", "-c",
		fmt.Sprintf("ps -eo pid,ppid,rss,pcpu,comm 2>/dev/null | awk -v want=%d 'NR==1 || $2==want'", pid))
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	if err := cmd.Run(); err != nil {
		return ""
	}
	out := strings.TrimSpace(stdout.String())
	if out != "" {
		peak = out
	}
	return peak
}

type Peak struct {
	MaxRSSMiB     float64
	MaxCPUPercent float64
	Samples       int
}

func summarisePeaks(path string) (Peak, error) {
	var p Peak
	data, err := os.ReadFile(path)
	if err != nil {
		return p, err
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 5 || fields[0] == "PID" {
			continue
		}
		if n, err := strconv.ParseFloat(fields[2], 64); err == nil {
			rssMiB := n / 1024.0
			if rssMiB > p.MaxRSSMiB {
				p.MaxRSSMiB = rssMiB
			}
		}
		if n, err := strconv.ParseFloat(fields[3], 64); err == nil && n > p.MaxCPUPercent {
			p.MaxCPUPercent = n
		}
		p.Samples++
	}
	return p, nil
}

// --- report ---------------------------------------------------------------------------

func writeReport(outDir string, rows Rows, peak Peak) error {
	var b strings.Builder
	b.WriteString("# v0.6 host measurement\n\n")
	fmt.Fprintf(&b, "Generated: %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(&b, "To taste hold: %s\n", TasteHold)
	fmt.Fprintf(&b, "Platform: %s/%s\n\n", runtime.GOOS, runtime.GOARCH)
	b.WriteString("| shot | terminal kind | wall clock |\n|---|---|---|\n")
	var total, span time.Duration
	var first, last time.Time
	for _, row := range rows {
		d := row.To.Sub(row.From)
		fmt.Fprintf(&b, "| %s | %s | %.3f s |\n", row.Shot, row.Kind, d.Seconds())
		total += d
		if first.IsZero() || row.From.Before(first) {
			first = row.From
		}
		if last.IsZero() || row.To.After(last) {
			last = row.To
		}
	}
	span = last.Sub(first)
	fmt.Fprintf(&b, "| whole run (span) | | %.3f s |\n", span.Seconds())
	fmt.Fprintf(&b, "| sum of per-Shot wall clocks | | %.3f s |\n", total.Seconds())
	if span.Seconds() > total.Seconds() {
		fmt.Fprintf(&b, "| overlap | | %.3f s |\n", (span - total).Seconds())
	}
	if peak.Samples > 0 {
		fmt.Fprintf(&b, "\nHost process peaks over %d samples: max RSS %.1f MiB, max CPU %.1f%%.\n",
			peak.Samples, peak.MaxRSSMiB, peak.MaxCPUPercent)
	} else {
		b.WriteString("\nHost peaks: not measured (no samples collected).\n")
	}
	b.WriteString("\nMachine facts: see `machine.txt` next to this report.\n")

	if err := os.WriteFile(filepath.Join(outDir, "report.md"), []byte(b.String()), 0o600); err != nil {
		return err
	}
	fmt.Printf("\nwrote %s\n", filepath.Join(outDir, "report.md"))
	return nil
}

// --- machine facts ---------------------------------------------------------------------

func writeMachineFacts(path string) error {
	var b strings.Builder
	fmt.Fprintf(&b, "date: %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(&b, "os: %s\n", runtime.GOOS)
	fmt.Fprintf(&b, "arch: %s\n", runtime.GOARCH)
	if isWSL() {
		b.WriteString("wsl2: yes\n")
		if data, err := os.ReadFile("/proc/version"); err == nil {
			fmt.Fprintf(&b, "kernel: %s\n", strings.TrimSpace(string(data)))
		}
	} else {
		b.WriteString("wsl2: no\n")
	}
	if runtime.GOOS == "linux" {
		if data, err := os.ReadFile("/proc/meminfo"); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				if strings.HasPrefix(line, "MemTotal") {
					b.WriteString(line + "\n")
				}
			}
		}
		if wd, err := os.Getwd(); err == nil {
			if strings.HasPrefix(wd, "/mnt/") {
				b.WriteString("project-fs: /mnt (9P)\n")
			} else {
				b.WriteString("project-fs: linux-native\n")
			}
		}
	} else if runtime.GOOS == "darwin" {
		b.WriteString("project-fs: native\n")
	}
	if n := runtime.NumCPU(); n > 0 {
		fmt.Fprintf(&b, "ncpu: %d\n", n)
	}
	return os.WriteFile(path, []byte(b.String()), 0o600)
}

func isWSL() bool {
	if runtime.GOOS != "linux" {
		return false
	}
	data, err := os.ReadFile("/proc/version")
	return err == nil && strings.Contains(strings.ToLower(string(data)), "microsoft")
}

func listDir(dir string) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return strings.Join(names, "\n")
}
