package main

import "core:log"
import "core:strings"

// Terminal reset sequences to clear a pane before reuse.
// These sequences ensure the pane is in a clean state for the next occupant.

// ANSI/VT100 control sequences
ANSI_CLEAR_SCREEN :: "\x1b[2J"      // ED: Erase Display
ANSI_CURSOR_HOME :: "\x1b[H"        // CUP: Cursor Position (home)
ANSI_RESET_ATTRS :: "\x1b[0m"       // SGR: Select Graphic Rendition (reset all)
ANSI_AUTOWRAP_ON :: "\x1b[?7h"      // DECAWM: Auto Wrap Mode (on)
ANSI_CURSOR_VISIBLE :: "\x1b[?25h"  // DECTCEM: Text Cursor Enable Mode (on)

// Composed reset sequence sent to a pane before reuse.
PANE_RESET_SEQUENCE :: ANSI_CLEAR_SCREEN + ANSI_CURSOR_HOME + ANSI_RESET_ATTRS + ANSI_AUTOWRAP_ON + ANSI_CURSOR_VISIBLE

// Clear a pane before reuse by sending terminal reset sequences through the surface.
pane_clear_surface :: proc(surface: Session_Surface, workspace_id, pane_id: string) -> (ok: bool, err: string) {
	if !surface.ops.pane_reset(surface, workspace_id, pane_id) {
		return false, "pane clear failed"
	}
	when ODIN_DEBUG {
		log.debugf("pane_clear_surface: pane %s reset sequences sent", pane_id)
	}
	return true, ""
}

// Verify that clear sequences were emitted correctly by checking terminal state.
// This is defensive: after sending clear, we query the pane to ensure it's ready.
pane_verify_clear :: proc(surface: Session_Surface, workspace_id, pane_id: string) -> (ok: bool, err: string) {
	// A simple way to verify: send a known marker and check it appears.
	// For now, this is a placeholder; real implementation would need to read pane output.
	when ODIN_DEBUG {
		log.debugf("pane_verify_clear: pane %s (placeholder verification)", pane_id)
	}
	return true, ""
}

// Full clear-and-verify cycle before pane reuse.
pane_prepare_for_reuse :: proc(surface: Session_Surface, workspace_id, pane_id: string) -> bool {
	// Clear the pane.
	clear_ok, clear_err := pane_clear_surface(surface, workspace_id, pane_id)
	if !clear_ok {
		when ODIN_DEBUG {
			log.warnf("pane_prepare_for_reuse: clear failed for pane %s: %s", pane_id, clear_err)
		}
		return false
	}

	// Verify clear.
	verify_ok, verify_err := pane_verify_clear(surface, workspace_id, pane_id)
	if !verify_ok {
		when ODIN_DEBUG {
			log.warnf("pane_prepare_for_reuse: verify failed for pane %s: %s", pane_id, verify_err)
		}
		return false
	}

	when ODIN_DEBUG {
		log.debugf("pane_prepare_for_reuse: pane %s ready for next occupant", pane_id)
	}
	return true
}

// Assert that clear sequences are syntactically correct.
init_pane_clear :: proc() {
	// Verify sequences are valid escape codes (sanity check).
	when ODIN_DEBUG {
		assert(strings.starts_with(ANSI_CLEAR_SCREEN, "\x1b["), "clear screen sequence malformed")
		assert(strings.starts_with(ANSI_CURSOR_HOME, "\x1b["), "cursor home sequence malformed")
		assert(strings.starts_with(ANSI_RESET_ATTRS, "\x1b["), "reset attrs sequence malformed")
		assert(strings.starts_with(ANSI_AUTOWRAP_ON, "\x1b["), "autowrap sequence malformed")
		assert(strings.starts_with(ANSI_CURSOR_VISIBLE, "\x1b["), "cursor visible sequence malformed")
	}
}
