package main

import "core:strings"
import "core:testing"

@(test)
test_parse_viewbox :: proc(t: ^testing.T) {
	width, height, ok := parse_viewbox(`<svg viewBox="0 0 640 480">`)
	testing.expect(t, ok)
	testing.expect_value(t, width, 640)
	testing.expect_value(t, height, 480)

	_, _, ok = parse_viewbox(`<svg viewBox="0 0 0 480">`)
	testing.expect(t, !ok, "zero-width viewBox is invalid")
	_, _, ok = parse_viewbox(`<svg>`)
	testing.expect(t, !ok, "missing viewBox is invalid")
}

@(test)
test_capture_html_fits_svg_and_hides_page_chrome :: proc(t: ^testing.T) {
	source := `<!doctype html><html><head><title>Diagram</title></head><body><main class="frame"><h1>Architecture</h1><div class="diagram-container"><svg viewBox="0 0 640 480"><rect width="640" height="480"/></svg></div></main></body></html>`
	captured, ok := make_capture_html(source, 640, 480)
	defer delete(captured)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(captured, "width:640px !important"))
	testing.expect(t, strings.contains(captured, "height:480px !important"))
	testing.expect(t, strings.contains(captured, "Architecture"), "source content remains intact")
	testing.expect(t, strings.contains(captured, "svg{display:block !important;width:640px !important;height:480px !important"), captured)
}
