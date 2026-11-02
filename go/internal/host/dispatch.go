package host

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/weima/coffee-shop/go/internal/proto"
	"github.com/weima/coffee-shop/go/internal/state"
)

// DefaultStationModel is the Pi Station default. An explicit Shot model overrides it.
const DefaultStationModel = "opencode-go/deepseek-v4.1-flash"

// ReplyStyle is prepended to every Shot's prompt, as the Odin host does, so a Station's
// answer is readable without the Barista repeating the rule.
const ReplyStyle = "Keep replies concise: lead with the answer, use short lists, and skip restating the question and filler."

// Shot kinds the host accepts.
const (
	ShotExecute  = "execute"
	ShotResearch = "research"
)

// ResearchTools is the read-only-plus-scratch allowlist. A research Shot gets no shell.
const ResearchTools = "read,grep,find,ls,write,codemode"

// ShotRequest is one Shot from a dispatch request.
type ShotRequest struct {
	ID       string
	Prompt   string
	Model    string
	Kind     string
	Taste    string
	Message  string
	Codemode bool
	// std is not part of the wire request; it is the request's parsing state.
}

// dispatcher owns the Slots, the queue and the running Stations.
type dispatcher struct {
	root      string
	cli       []string // argv prefix for the Odin CLI: the seam
	socket    string
	extension string
	model     string

	slots   *slots
	w       *writer
	sampler *stationSampler

	mu      sync.Mutex
	running map[string]*stationRun
	queue   []queuedShot
	repo    string // repository of the current dispatch, for queued Shots
}

type stationRun struct {
	requestID string
	shotID    string
	cmd       *exec.Cmd
	log       *boundedLog
	stdin     io.WriteCloser // the Station's input: a reply is one line written here
	terminal  bool           // a terminal report was relayed
	exited    bool           // the process is gone, so it must not be signalled again
}

// queuedShot is a Shot waiting for a Slot, with everything needed to start it later.
type queuedShot struct {
	requestID  string
	shot       ShotRequest
	promptPath string
	stationDir string
}

func newDispatcher(root string, cli []string, socket, extension, model string, w *writer) *dispatcher {
	if model == "" {
		model = DefaultStationModel
	}
	return &dispatcher{
		root:      root,
		cli:       cli,
		socket:    socket,
		extension: extension,
		model:     model,
		slots:     newSlots(SlotCapacity).withMachineLimit(root),
		w:         w,
		sampler:   newStationSampler(root),
		running:   make(map[string]*stationRun),
	}
}

// dispatchRequest is the wire shape this slice accepts. Unknown fields are ignored, as in
// the Odin host; the recipe is validated field by field here.
type dispatchRequest struct {
	Repo   string `json:"repo"`
	Recipe struct {
		Shots []struct {
			ID       string `json:"id"`
			Prompt   string `json:"prompt"`
			Model    string `json:"model"`
			Kind     string `json:"kind"`
			Taste    string `json:"taste"`
			Message  string `json:"message"`
			Codemode *bool  `json:"codemode"`
		} `json:"shots"`
	} `json:"recipe"`
}

// dispatch validates the whole request before touching the repository or starting
// anything, then starts what fits and queues the rest.
func (d *dispatcher) dispatch(ctx context.Context, requestID string, raw json.RawMessage) {
	var request dispatchRequest
	if err := json.Unmarshal(raw, &request); err != nil {
		d.w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: "invalid dispatch request"})
		return
	}
	if !filepath.IsAbs(request.Repo) {
		d.w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: "repo must be an absolute path"})
		return
	}
	if len(request.Recipe.Shots) == 0 {
		d.w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: "recipe needs at least one shot"})
		return
	}

	shots := make([]ShotRequest, 0, len(request.Recipe.Shots))
	seen := make(map[string]bool, len(request.Recipe.Shots))
	for _, shot := range request.Recipe.Shots {
		if !validShotID(shot.ID) || strings.TrimSpace(shot.Prompt) == "" {
			d.w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: "each shot needs a valid id and a prompt"})
			return
		}
		if seen[shot.ID] {
			d.w.emit(proto.Event{Type: "error", RequestID: requestID, Reason: "shot ids must be unique"})
			return
		}
		seen[shot.ID] = true

		kind := shot.Kind
		if kind == "" {
			kind = ShotExecute
		}
		if kind != ShotExecute && kind != ShotResearch {
			d.w.emit(proto.Event{Type: "error", RequestID: requestID, ShotID: shot.ID, Reason: "shot kind must be execute or research"})
			return
		}
		if shot.Taste != "" {
			if kind != ShotExecute {
				d.w.emit(proto.Event{Type: "error", RequestID: requestID, ShotID: shot.ID, Reason: "shot taste needs an execute kind"})
				return
			}
			if strings.TrimSpace(shot.Message) == "" || len(shot.Message) > 200 || strings.ContainsAny(shot.Message, "\r\n") {
				d.w.emit(proto.Event{Type: "error", RequestID: requestID, ShotID: shot.ID, Reason: "shot message is required with a taste and must be 1 to 200 characters on one line"})
				return
			}
		}
		model := shot.Model
		if model == "" {
			model = d.model
		}
		if len(model) > 80 {
			d.w.emit(proto.Event{Type: "error", RequestID: requestID, ShotID: shot.ID, Reason: "shot model must be 1 to 80 characters using letters, digits, /, ., -, _, or :"})
			return
		}
		codemode := true
		if shot.Codemode != nil {
			codemode = *shot.Codemode
		}
		shots = append(shots, ShotRequest{ID: shot.ID, Prompt: shot.Prompt, Model: model, Kind: kind, Taste: shot.Taste, Message: shot.Message, Codemode: codemode})
	}

	d.mu.Lock()
	d.repo = request.Repo
	d.mu.Unlock()
	d.w.emit(proto.Event{Type: "dispatch_accepted", RequestID: requestID})
	for _, shot := range shots {
		d.startOrQueue(ctx, requestID, request.Repo, shot)
	}
}

// startOrQueue starts a Shot when a Slot is free, otherwise queues it.
func (d *dispatcher) startOrQueue(ctx context.Context, requestID, repo string, shot ShotRequest) {
	if reason, ok := d.slots.acquireWithReason(requestID, shot.ID); !ok {
		if reason != "" {
			d.w.emit(proto.Event{Type: "warning", RequestID: requestID, ShotID: shot.ID, Reason: reason})
		}
		d.mu.Lock()
		d.queue = append(d.queue, queuedShot{requestID: requestID, shot: shot})
		d.mu.Unlock()
		d.w.emit(proto.Event{Type: "dispatch_queued", RequestID: requestID, ShotID: shot.ID})
		return
	}

	promptPath := state.PromptPath(d.root, requestID, shot.ID)
	stationDir := state.StationDir(d.root, requestID, shot.ID)
	branch := fmt.Sprintf("cs-host-%s-%s", requestID, shot.ID)

	if err := d.prepare(requestID, shot, repo, branch, stationDir, promptPath); err != nil {
		d.fail(requestID, shot.ID, err.Error())
		return
	}
	if err := d.launch(ctx, requestID, shot, promptPath, stationDir); err != nil {
		d.fail(requestID, shot.ID, err.Error())
	}
}

// prepare writes the prompt and creates the Shot's worktree through the Odin seam, so the
// repository work stays in one implementation while orchestration lives here.
func (d *dispatcher) prepare(requestID string, shot ShotRequest, repo, branch, stationDir, promptPath string) error {
	if err := state.EnsureDir(filepath.Dir(promptPath), true); err != nil {
		return fmt.Errorf("create prompts directory: %w", err)
	}
	prompt := ReplyStyle + "\n\n" + shot.Prompt
	if err := os.WriteFile(promptPath, []byte(prompt), 0o600); err != nil {
		return fmt.Errorf("write prompt file: %w", err)
	}
	if err := state.EnsureDir(filepath.Dir(stationDir), true); err != nil {
		return fmt.Errorf("create stations directory: %w", err)
	}
	argv := append(append([]string{}, d.cli...), "prepare", "--repo", repo, "--branch", branch, "--dir", stationDir)
	output, err := runQuiet(argv)
	if err != nil {
		return fmt.Errorf("%s", seamReason(output, err))
	}
	return nil
}

// launch starts the Station with its output going to a bounded per-Shot log.
func (d *dispatcher) launch(ctx context.Context, requestID string, shot ShotRequest, promptPath, stationDir string) error {
	logPath := state.LogPath(d.root, requestID, shot.ID)
	if err := state.EnsureDir(filepath.Dir(logPath), true); err != nil {
		return fmt.Errorf("create logs directory: %w", err)
	}
	log, err := openBoundedLog(logPath, LogLimit)
	if err != nil {
		return fmt.Errorf("open Shot log: %w", err)
	}

	// The Pi extension is installed at startup by csd (extension.Install) or, for the Odin
	// host, by the Odin binary's own prepare step; it is not created here. Without it a
	// Station starts and immediately fails to load its tools, so refuse here instead of
	// logging a mysterious exit.
	if d.extension != "" {
		if _, err := os.Stat(d.extension); err != nil {
			return fmt.Errorf("the Pi extension is missing at %s; csd installs it at startup (extension.Install)", d.extension)
		}
	}

	argv := d.stationArgv(requestID, shot, promptPath)
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = stationDir
	stdin, err := cmd.StdinPipe() // writes become the Station's stdin, reads are impossible
	if err != nil {
		_ = log.Close()
		return fmt.Errorf("open Station input: %w", err)
	}
	cmd.Stdout = log
	cmd.Stderr = log
	// The Station gets its own process group so a cancel can reach the whole tree.
	setProcessGroup(cmd)
	cmd.Cancel = func() error { return killProcessGroup(cmd) }
	cmd.WaitDelay = waitDelay

	if err := cmd.Start(); err != nil {
		_ = log.Close()
		return fmt.Errorf("could not start the Station: %w", err)
	}

	run := &stationRun{requestID: requestID, shotID: shot.ID, cmd: cmd, log: log, stdin: stdin}
	d.mu.Lock()
	d.running[slotKey(requestID, shot.ID)] = run
	d.mu.Unlock()
	// The slot key is the Station's session id, which is what a reply and a cancel
	// address; the alert carries it so a reader can act on the same handle.
	d.w.stationStarted(requestID, shot.ID, slotKey(requestID, shot.ID))
	// Sampling starts with the process, so the gate's 5.9 record covers the whole Shot.
	d.sampler.track(requestID, shot.ID, cmd.Process.Pid)
	d.w.emit(proto.Event{Type: "session_started", RequestID: requestID, ShotID: shot.ID})

	go func() {
		_ = cmd.Wait()
		_ = stdin.Close()
		_ = log.Close()
		d.processExited(requestID, shot.ID)
	}()
	return nil
}

// stationArgv builds the Station command. No shell is involved, so no path or prompt text
// needs quoting: this is the defect class the port exists to remove.
func (d *dispatcher) stationArgv(requestID string, shot ShotRequest, promptPath string) []string {
	argv := append(append([]string{}, d.cli...), "station",
		"--kind", shot.Kind,
		"--report", d.socket,
		"--station", shot.ID,
		"--brew", requestID,
		"--prompt-file", promptPath,
	)
	if shot.Taste != "" {
		argv = append(argv, "--taste", shot.Taste, "--message", shot.Message)
	}
	if !shot.Codemode {
		argv = append(argv, "--codemode", "false")
	}
	agent := "pi"
	if override := os.Getenv("CS_AGENT"); override != "" {
		// A test seam, and the same idea as the Odin host's "-- <agent>": the Station is
		// harness-neutral, so the agent command is data.
		agent = override
	}
	argv = append(argv, "--", agent, "--mode", "rpc")
	if shot.Kind == ShotResearch {
		argv = append(argv, "--tools", ResearchTools)
	} else if shot.Codemode {
		argv = append(argv, "--tools", "+codemode")
	}
	argv = append(argv, "--model", shot.Model, "-e", d.extension)
	return argv
}

// terminalReport records a terminal report and releases the Shot.
func (d *dispatcher) terminalReport(requestID, shotID string) {
	d.mu.Lock()
	if run, ok := d.running[slotKey(requestID, shotID)]; ok {
		run.terminal = true
	}
	d.mu.Unlock()
	d.release(requestID, shotID)
}

// processExited frees a Station that ended without a terminal report.
func (d *dispatcher) processExited(requestID, shotID string) {
	d.mu.Lock()
	run, ok := d.running[slotKey(requestID, shotID)]
	terminal := ok && run.terminal
	if ok {
		run.exited = true
		delete(d.running, slotKey(requestID, shotID))
	}
	d.mu.Unlock()
	if !terminal {
		d.release(requestID, shotID)
	}
}

// CancelGrace bounds how long a cancelled Station gets between SIGTERM and SIGKILL.
const CancelGrace = 2 * time.Second

// cancel stops one Shot, or every Shot of a request when shotID is empty. The Station is
// asked first and killed only if it does not go: its own cancel path stops the agent, which
// is the half that lives in Odin.
func (d *dispatcher) cancel(requestID, shotID string) {
	d.mu.Lock()
	targets := make([]*stationRun, 0, len(d.running))
	for _, run := range d.running {
		if run.requestID != requestID {
			continue
		}
		if shotID == "" || run.shotID == shotID {
			targets = append(targets, run)
		}
	}
	d.mu.Unlock()

	if len(targets) == 0 {
		if shotID == "" {
			d.w.emit(proto.Event{Type: "cancelled", RequestID: requestID, Reason: "no Stations are running"})
		} else {
			d.w.emit(proto.Event{Type: "cancelled", RequestID: requestID, ShotID: shotID, Reason: "no Station is running for that shot"})
		}
		return
	}
	for _, run := range targets {
		run := run
		d.w.emit(proto.Event{Type: "cancelled", RequestID: run.requestID, ShotID: run.shotID})
		_ = killProcessGroup(run.cmd)
		// Escalate once, and only for a Station that is still there: the flag is written
		// under the same mutex that the exit path takes, so this cannot kill a reaped pid.
		go func() {
			time.Sleep(CancelGrace)
			d.mu.Lock()
			gone := run.exited
			d.mu.Unlock()
			if !gone {
				_ = killProcessGroupHard(run.cmd)
			}
		}()
	}
}

// release frees the Slot and starts whatever was waiting for one.
func (d *dispatcher) release(requestID, shotID string) {
	if !d.slots.release(requestID, shotID) {
		return // already released by the other path
	}
	d.w.stationFinished(requestID, shotID)
	d.sampler.finish(requestID, shotID)
	d.drainQueue()
}

// drainQueue starts queued Shots while Slots are free.
func (d *dispatcher) drainQueue() {
	for {
		d.mu.Lock()
		if len(d.queue) == 0 {
			d.mu.Unlock()
			return
		}
		next := d.queue[0]
		d.queue = d.queue[1:]
		d.mu.Unlock()

		if !d.slots.acquire(next.requestID, next.shot.ID) {
			d.mu.Lock()
			d.queue = append([]queuedShot{next}, d.queue...)
			d.mu.Unlock()
			return
		}
		d.w.emit(proto.Event{Type: "dispatch_dequeued", RequestID: next.requestID, ShotID: next.shot.ID})

		repo := d.repoFor(next.requestID)
		if err := d.prepare(next.requestID, next.shot, repo, fmt.Sprintf("cs-host-%s-%s", next.requestID, next.shot.ID), state.StationDir(d.root, next.requestID, next.shot.ID), state.PromptPath(d.root, next.requestID, next.shot.ID)); err != nil {
			d.fail(next.requestID, next.shot.ID, err.Error())
			continue
		}
		if err := d.launch(context.Background(), next.requestID, next.shot, state.PromptPath(d.root, next.requestID, next.shot.ID), state.StationDir(d.root, next.requestID, next.shot.ID)); err != nil {
			d.fail(next.requestID, next.shot.ID, err.Error())
		}
	}
}

// sampleStations reads every live Station once. The host calls it on a ticker.
func (d *dispatcher) sampleStations() { d.sampler.sample() }

// shutdown returns every machine slot this host holds, so a restart is never blocked by
// a host that exited while holding them.
func (d *dispatcher) shutdown() { d.slots.releaseAll() }

// repoFor remembers the repository of each request so a queued Shot can be started later.
func (d *dispatcher) repoFor(requestID string) string { return d.repo }

// fail reports a Shot that could not start and frees its Slot.
func (d *dispatcher) fail(requestID, shotID, reason string) {
	d.w.emit(proto.Event{Type: "session_failed", RequestID: requestID, ShotID: shotID, Reason: reason})
	if d.slots.release(requestID, shotID) {
		go d.drainQueue()
	}
}

// seamReason turns the seam's JSON error into a sentence, falling back to the message.
func seamReason(output string, err error) string {
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		var message struct {
			Reason string `json:"reason"`
		}
		if json.Unmarshal([]byte(line), &message) == nil && message.Reason != "" {
			return message.Reason
		}
	}
	if output != "" {
		return strings.TrimSpace(output)
	}
	return err.Error()
}

// runQuiet runs a seam command and returns its combined output.
func runQuiet(argv []string) (string, error) {
	cmd := exec.Command(argv[0], argv[1:]...)
	var out strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return out.String(), err
	}
	return out.String(), nil
}
