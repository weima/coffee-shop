package main

import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Options :: struct {
	source: string `args:"pos=0,required" usage:"Self-contained diagram HTML file."`,
	output: string `usage:"Output PNG path; defaults beside the source."`,
	scale: int `usage:"Device scale factor (1-4). Default: 2."`,
	browser: string `usage:"Chromium executable. Default: CHROME_BIN or google-chrome."`,
}

main :: proc() {
	options := Options{scale = 2}
	flags.parse_or_exit(&options, os.args, .Unix)
	if options.scale < 1 || options.scale > 4 {
		fail("--scale must be between 1 and 4")
	}

	input, err := os.read_entire_file(options.source, context.allocator)
	if err != nil {
		failf("cannot read {}: {}", options.source, err)
	}
	defer delete(input)

	width, height, dimensions_ok := diagram_dimensions(string(input))
	if !dimensions_ok {
		fail("input must contain an SVG with an integer viewBox: min-x min-y width height")
	}
	if width > 10000 || height > 10000 || width*height*options.scale*options.scale > 50_000_000 {
		fail("requested image is too large; reduce the SVG dimensions or --scale")
	}

	captured, capture_ok := make_capture_html(string(input), width, height)
	if !capture_ok {
		fail("input must be an HTML document with a closing </head> tag")
	}
	defer delete(captured)

	output := options.output
	if output == "" {
		filename := fmt.tprintf("{}.png", filepath.stem(options.source))
		directory := filepath.dir(options.source)
		if directory == "" {
			output = filename
		} else {
			output, _ = filepath.join({directory, filename})
		}
	}
	absolute_output: string
	if os.is_absolute_path(output) {
		cloned, clone_err := strings.clone(output, context.allocator)
		if clone_err != nil {
			fail("cannot allocate output path")
		}
		absolute_output = cloned
	} else {
		working_directory, cwd_err := os.get_working_directory(context.allocator)
		if cwd_err != nil {
			failf("cannot resolve output path: {}", cwd_err)
		}
		joined, join_err := filepath.join({working_directory, output})
		delete(working_directory)
		if join_err != nil {
			fail("cannot allocate absolute output path")
		}
		absolute_output = joined
	}
	defer delete(absolute_output)

	temp_dir, temp_err := os.make_directory_temp("", "diagram-export-*", context.allocator)
	if temp_err != nil {
		failf("cannot create a temporary directory: {}", temp_err)
	}
	defer os.remove_all(temp_dir)

	html_path, html_path_err := filepath.join({temp_dir, "capture.html"})
	png_path, png_path_err := filepath.join({temp_dir, "capture.png"})
	if html_path_err != nil || png_path_err != nil {
		fail("cannot allocate temporary paths")
	}
	defer delete(html_path)
	defer delete(png_path)
	if err = os.write_entire_file(html_path, captured, os.Permissions{.Read_User, .Write_User}); err != nil {
		failf("cannot write temporary capture document: {}", err)
	}

	browser := options.browser
	if browser == "" {
		browser = os.get_env("CHROME_BIN", context.allocator)
	}
	if browser == "" {
		browser = "google-chrome"
	}
	url := fmt.tprintf("file://{}", html_path)
	window_size := fmt.tprintf("--window-size={},{}", width, height)
	scale := fmt.tprintf("--force-device-scale-factor={}", options.scale)
	screenshot := fmt.tprintf("--screenshot={}", png_path)
	command := []string{
		browser,
		"--headless",
		"--disable-gpu",
		"--no-first-run",
		"--no-default-browser-check",
		"--hide-scrollbars",
		window_size,
		scale,
		screenshot,
		url,
	}
	state, stdout, stderr, process_err := os.process_exec(os.Process_Desc{command = command}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)
	if process_err != nil {
		failf("could not launch {}: {}", browser, process_err)
	}
	if !state.success {
		message := string(stderr)
		if len(message) > 1200 {
			message = message[:1200]
		}
		failf("Chromium exited with code {}: {}", state.exit_code, message)
	}
	if err = os.rename(png_path, absolute_output); err != nil {
		failf("cannot write {}: {}", absolute_output, err)
	}
	fmt.printfln("Wrote {} ({} x {} at {}x)", absolute_output, width*options.scale, height*options.scale, options.scale)
}

// Parse only the SVG opening tag; CSS uses its viewBox dimensions as the capture viewport.
diagram_dimensions :: proc(html: string) -> (width, height: int, ok: bool) {
	svg_start := strings.index(html, "<svg")
	if svg_start < 0 {
		return
	}
	tag_end := strings.index(html[svg_start:], ">")
	if tag_end < 0 {
		return
	}
	return parse_viewbox(html[svg_start : svg_start+tag_end+1])
}

parse_viewbox :: proc(svg_tag: string) -> (width, height: int, ok: bool) {
	attribute := strings.index(svg_tag, "viewBox=\"")
	if attribute < 0 {
		return
	}
	value_start := attribute + len("viewBox=\"")
	value_end := strings.index(svg_tag[value_start:], "\"")
	if value_end < 0 {
		return
	}
	fields, fields_err := strings.fields(svg_tag[value_start : value_start+value_end])
	if fields_err != nil {
		return
	}
	defer delete(fields)
	if len(fields) != 4 {
		return
	}
	width_value, width_ok := strconv.parse_int(fields[2])
	if !width_ok || width_value <= 0 {
		return 0, 0, false
	}
	height_value, height_ok := strconv.parse_int(fields[3])
	if !height_ok || height_value <= 0 {
		return 0, 0, false
	}
	return width_value, height_value, true
}

make_capture_html :: proc(html: string, width, height: int) -> (string, bool) {
	head_end := strings.index(html, "</head>")
	if head_end < 0 {
		return "", false
	}
	style := fmt.tprintf(`<style>
html,body{{width:{}px !important;height:{}px !important;margin:0 !important;padding:0 !important;overflow:hidden !important;background:transparent !important}}
.frame{{display:block !important;width:{}px !important;max-width:none !important;height:{}px !important;margin:0 !important;padding:0 !important;overflow:hidden !important}}
.frame>header,.frame>h1,.frame>.eyebrow,.frame>.summary,.frame>.footer,.frame>.caption,.frame>.legend{{display:none !important}}
.diagram-container{{display:block !important;width:{}px !important;height:{}px !important;margin:0 !important;padding:0 !important;overflow:hidden !important}}
svg{{display:block !important;width:{}px !important;height:{}px !important;max-width:none !important;margin:0 !important}}
</style>`, width, height, width, height, width, height, width, height)
	captured, err := strings.concatenate({html[:head_end], style, html[head_end:]})
	return captured, err == nil
}

fail :: proc(message: string) -> ! {
	fmt.eprintfln("diagram-export: {}", message)
	os.exit(1)
}

failf :: proc(format: string, args: ..any) -> ! {
	message := fmt.tprintf(format, ..args)
	fmt.eprintfln("diagram-export: {}", message)
	os.exit(1)
}
