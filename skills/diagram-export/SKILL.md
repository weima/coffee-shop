---
name: diagram-export
description: Turn a natural-language description or source document into an architecture, flow, sequence, state, or other diagram, then render it as a PNG.
---

# Create and export diagrams

This skill is the complete authoring and export workflow for diagrams. It accepts a natural-language description or source document for any subject and does not require the Coffee Shop repository. The skill folder includes the Odin exporter source. Its only runtime dependencies are Odin and headless Chrome.

## Workflow

1. Use the user's description and any named source document to identify the audience, purpose, and key facts. If the request points to repository architecture, inspect the relevant code or docs; do not assume the subject is Coffee Shop. Choose a form that explains it directly: architecture for boundaries and dependencies, sequence for ordered interactions, flow for decisions, state diagram for lifecycle, or data model for entities and relationships. For a plural request such as “flow charts for my architecture document,” identify the distinct flows in that source and make one focused diagram per flow rather than combining unrelated flows.
2. Keep the content focused. Name the main actors or concepts, show only relationships that answer the question, label connections with meaningful verbs, and make direction and alternatives explicit.
3. Create a self-contained HTML document with inline SVG. Use a consistent visual hierarchy, legible labels, restrained colors, aligned elements, and enough spacing to avoid overlaps. Include a concise title or description in the diagram when it helps interpretation. Do not depend on external fonts, stylesheets, scripts, or images.
4. Save the HTML source where the user requests. Otherwise, put it beside the relevant document or in a `diagrams/` directory. The first SVG must have a `viewBox` with integer width and height; include a closing `</head>` tag.
5. Review the source for factual accuracy and visual clarity, then render a 2× PNG preview using this skill's installed directory as the Odin package:

   ```sh
   odin run /absolute/path/to/diagram-export -- path/to/diagram.html
   ```

   The exporter writes `path/to/diagram.png`. To choose another destination or scale:

   ```sh
   odin run /absolute/path/to/diagram-export -- path/to/diagram.html --output path/to/preview.png --scale 2
   ```

6. Open or inspect the PNG. Confirm that labels are readable, content is not clipped or overlapped, and the result answers the original question. If it does not, revise the HTML and render again. Keep the HTML source and PNG preview together when they are documentation assets.
7. Report both paths and any rendering limitation.

## Requirements and limits

- The bundled Odin source is `main.odin` beside this `SKILL.md`. Check that `odin` and a headless Chrome executable are available before rendering. The exporter uses `CHROME_BIN` when set; otherwise it runs `google-chrome`. If needed, select an installed alternative with `--browser chromium`.
- The exporter uses headless Chromium directly. Do not add Playwright, Python, or a separate SVG rasterizer to this workflow.
- If Odin or Chromium is not installed, stop and ask the user to install the missing dependency. If rendering fails for another reason, report the error; do not silently switch renderers.
- During development, `tools/diagram-export/` is the source of truth. Keep its implementation and tests synchronized with the bundled `main.odin` and `main_test.odin`; the skill package must remain runnable without the Coffee Shop repository. A future shared tools repository may become the source of truth.
- The source must be self-contained; external fonts, stylesheets, scripts, or images can make output depend on network access.
- The raster size follows the SVG `viewBox` width and height multiplied by `--scale` (1–4). Keep the resulting image within the exporter's 50-megapixel limit.
- The tool emits PNG only. Its CSS hides common HTML page chrome and fits the SVG to the capture viewport; it does not rewrite the source HTML.
