package host

import (
	"fmt"
	"os"
	"os/exec"
	"testing"
	"time"
)

// holderEnv turns the test binary into a slot holder in another process, which is the only
// way to prove an advisory lock excludes a second holder: flock is per open file, so a
// single process can take it twice and learn nothing.
const holderEnv = "CS_SLOT_HOLDER"

// A holder takes a machine slot under holderEnv, reports the index, and holds it until its
// stdin closes, so the parent decides when the lock goes away.
func runSlotHolder(t *testing.T, root string) (*exec.Cmd, int) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=TestSlotHolderProcess")
	cmd.Env = append(os.Environ(), holderEnv+"="+root, fakeCLIEnv+"=")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("holder stdin: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("holder stdout: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start holder: %v", err)
	}
	t.Cleanup(func() {
		_ = stdin.Close()
		_ = cmd.Wait()
	})

	var index int
	if _, err := fmt.Fscanf(stdout, "%d\n", &index); err != nil {
		t.Fatalf("holder did not report a slot: %v", err)
	}
	return cmd, index
}

// TestSlotHolderProcess is the child side; it does nothing under a normal run.
func TestSlotHolderProcess(t *testing.T) {
	root := os.Getenv(holderEnv)
	if root == "" {
		t.Skip("only runs as a slot holder")
	}
	slot, _, ok := tryAcquireMachineSlot(root, 1)
	if !ok {
		t.Fatalf("holder could not take slot 0")
	}
	fmt.Printf("%d\n", slot.index)
	_ = os.Stdout.Sync()
	buf := make([]byte, 1)
	for {
		// Hold the lock until the parent closes stdin.
		if _, err := os.Stdin.Read(buf); err != nil {
			break
		}
	}
	slot.release()
}

// A machine slot held by another process is not available here, and becomes available when
// that process exits: the kernel drops the lock, so no pid bookkeeping decides it.
func TestMachineSlotExcludesAnotherProcess(t *testing.T) {
	root := shortRoot(t)
	holder, index := runSlotHolder(t, root)
	if index != 0 {
		t.Fatalf("holder took slot %d, want 0", index)
	}

	if _, reason, ok := tryAcquireMachineSlot(root, 1); ok {
		t.Fatal("a slot held by another process must not be acquirable here")
	} else if reason == "" {
		t.Fatal("a refusal should say why")
	}

	// Ending the holder drops the lock without any cleanup on our side.
	_ = holder.Process.Signal(os.Interrupt)
	_ = holder.Wait()
	for i := 0; i < 200; i++ {
		if _, _, ok := tryAcquireMachineSlot(root, 1); ok {
			return
		}
		// Closing the holder's stdin is what ends it in the cleanup path; here the signal
		// should be enough, so a short retry covers the process teardown.
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the slot should be free once the holder process exits")
}

// A host that exits returns its machine slots, so the next host is never blocked.
func TestMachineSlotsReleaseAll(t *testing.T) {
	root := shortRoot(t)
	m := newMachineSlots(root, 2)
	if reason, ok := m.acquire("req-1", "shot-a"); !ok {
		t.Fatalf("acquire: %s", reason)
	}
	m.releaseAll()
	if _, _, ok := tryAcquireMachineSlot(root, 2); !ok {
		t.Fatal("after releaseAll the slot must be free")
	}
}
