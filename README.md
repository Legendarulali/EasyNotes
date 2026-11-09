# EasyNotes

Handwritten note-taking prototype for Android, iOS and Windows/Linux 2-in-1s.
**Rust** owns the document: stroke processing, shape recognition, erasing, the spatial index, pages, PDF import, saving and PDF export.
**Flutter** owns the library screens, input routing, rendering and UI.
They talk through `flutter_rust_bridge` 2.13.

```
easynotes/
├── rust_engine/                    Rust crate (cdylib/staticlib, built by cargokit)
│   └── src/
│       ├── geometry/               point.rs, stroke.rs, outline.rs (variable-width tessellation),
│       │                           shape_detector.rs (instant rectangle / quadrilateral snap), sticky_note.rs
│       ├── spatial/                quadtree.rs, hit_test.rs, transform.rs (bbox scale/drag, page clamps)
│       ├── document/               Engine (mod.rs): strokes, notes, selection, clipboard, revisions
│       │   ├── page.rs             1000 × 1000 pages, vertical stacking, DocumentKind
│       │   ├── eraser.rs           stroke eraser + partial ("classic") eraser that cuts strokes
│       │   ├── pdf_importer.rs     PDF page tree → page backgrounds (lopdf)
│       │   ├── storage.rs          notebook file format (versioned, zlib-compressed JSON)
│       │   └── paper.rs            paper specs (ruled / grid / blank)
│       ├── export/                 pdf_exporter.rs (vector PDF), pdf_embed.rs (imported pages as Form XObjects)
│       └── api/stroke_api.rs       FFI surface (scanned by frb codegen)
└── flutter_app/
    └── lib/
        ├── main.dart               dark "smokey" theme, opens the library
        ├── screens/                home_screen.dart (library), editor_screen.dart
        ├── widgets/                draggable_toolbar.dart, canvas_status_bar.dart, editor_app_bar.dart
        └── src/
            ├── editor/             EditorController (engine calls, open/autosave), tools
            ├── canvas/             NoteCanvas (input), painters (pages, PDF layer, ink), viewport, scene cache
            ├── services/           library (folders/notebooks on disk), PDF rasteriser (pdfrx), export/share
            ├── ui/                 hex colour picker, selection actions, sticky-note editor
            └── rust/               generated bindings (do not edit)
```

## Features

- **Library.** The app starts on a dark `#1E1E1E` dashboard.
  - The **New** menu creates a *Ruled Notebook*, a *Grid Notebook*, a *Blank Whiteboard* or a *New Folder*. **Import PDF…** creates an annotation notebook.
  - Each card has *Rename*, *Move to…* and *Delete*, via the ⋮ button, a long press or a right-click.
  - Notebooks autosave, and their card shows a thumbnail of the first page.
- **Pages.** Notebook pages are exactly 1000 × 1000 units, stacked with no gap (page *n* spans y ∈ [1000·n, 1000·(n+1))).
  - Scrolling (or wheeling) past the last page appends a new page beneath it.
  - Content that reaches below the last page, such as a stroke, a moved selection or a pasted item, appends pages to fit.
  - Ink and notes are kept inside the 1000-unit page column. Whiteboards are unbounded towards +X / +Y.
- **PDF annotation.** Imported PDFs become one page per PDF page: 1000 units wide, keeping the PDF page's aspect ratio.
  - PDFium (via `pdfrx`) renders each page as the background layer at a resolution that follows the zoom.
  - Exporting re-embeds the original pages as **vector Form XObjects** under the annotations, so text stays selectable and nothing is rasterised. MediaBox/CropBox/Rotate inheritance is handled.
- **Instant shape snap.** On pen-up, Rust checks whether the stroke is a quadrilateral and snaps it to a sharp 90° rectangle.
  - First an O(n) closure gate: pen-up must land near pen-down, and overshoot is trimmed.
  - Then the loop is resampled and corners are found with a "short straw" test. Exactly 4 straight sides at about 90° are required.
  - Sloppy trapezoids and parallelograms are squared up. Rotations under 8° become axis-aligned.
  - It takes about 30 µs for a 600-sample stroke (release build), and an open stroke is rejected in about 6 µs.
- **Two erasers.** The *Stroke eraser* deletes whole strokes on contact.
  - The *Classic eraser* cuts strokes exactly where it passes. Each stroke segment gets one exact erased interval (the distance to the eraser's swept capsule is convex), and the pieces become separate strokes.
  - The first piece keeps the original id and z-order. A cut rectangle stays one open shape with sharp corners.
- **Floating toolbar.** Tools, palette, custom hex colour, thickness and eraser mode live in a panel you drag by its grip.
  - It snaps to the top, bottom, left, right or any corner (left/right docks are vertical), or stays where you drop it.
  - It can collapse to a single button, and its position is remembered.
- **Status bar.** Shows zoom, the pan offsets (`X`/`Y` = world point at the top-left of the canvas), the current page and a tool hint.
  - Tapping it (or Ctrl+0) **only** resets the zoom to 100%: the vertical offset is kept, and so is the horizontal one unless the whole page width fits at 100%, in which case the page is centred.
- Unchanged from the first version: pen, pencil, highlighter (multiply blend beneath ink), sticky notes, lasso and box selection with resize handles, and cut/copy/duplicate/paste/delete.

## Design notes

- **One tessellator.** Rust turns each stroke into world-space render geometry (`StrokeRender`), and both Flutter and the PDF exporter draw the same geometry.
  - Filled outline for pen and pencil.
  - Centre line for the highlighter.
  - Closed polygon for snapped rectangles.
  - Open miter-joined polyline for cut shapes.
- **Rust is authoritative for layout.** `DocumentInfo.pages` (top, height, `pdf_page`) drives the Flutter painter, the viewport extent and the PDF exporter. Paper patterns restart at each page's top, identically on screen and in the PDF.
- **Persistence.** A notebook is a folder `Name.enote/` containing:
  - `content.ezn`: the engine document, `EZNOTE\x01\n` + zlib(JSON). Enums are stored as strings and coordinates rounded to 0.01. It is written atomically (temp file + rename).
  - `background.pdf`, `meta.json` and `thumb.png`.

  Folders are plain directories under `Documents/EasyNotes`. Saves are debounced 2 s after the last edit; leaving the editor, backgrounding the app or Ctrl+S save immediately. A revision counter in the engine tracks what is dirty.
- **Export page sizes.** Notebook pages export as 750 × 750 pt (1 unit = 0.75 pt, so the 5 mm grid stays 5 mm on paper). PDF-backed pages keep the source size, and blank pages appended after them reuse that scale. Whiteboards are cut into A-series pages covering the content.

## Input model

| Device | Behaviour |
|---|---|
| Stylus | Draws / erases / selects with the active tool. Eraser end of the pen (`invertedStylus`) always erases. |
| First stylus contact | Switches on **stylus-only** mode: fingers pan and zoom, touches during a pen stroke are ignored (palm rejection). |
| Finger | Stylus-only on: one finger pans, two fingers pinch-zoom. Stylus-only off: one finger draws, two fingers navigate. Toggle in the top bar. |
| Finger / pen on selection | Drag inside the box to move it, drag a corner handle to resize (Shift keeps the ratio). |
| Mouse | Left button draws. Right/middle drag pans. Wheel scrolls (Shift = horizontal; past the last page appends one); Ctrl+wheel zooms. Trackpad pinch zooms. |
| Keyboard | Ctrl+C / X / V / D, Del, Esc, Ctrl+S (save), Ctrl+0 (reset zoom) |

## Running it

Prerequisites: Flutter ≥ 3.47 (Dart 3.13), Rust stable ≥ 1.88, `flutter_rust_bridge_codegen` 2.13.0.

| Target | Needs |
|---|---|
| Android | Android SDK + NDK (Flutter's Gradle plugin installs NDK `28.2.13676358` automatically) |
| iOS | Xcode (build on macOS) |
| Windows | Visual Studio 2022/2026 (Build Tools) with *Desktop development with C++*, the `x86_64-pc-windows-msvc` Rust target, and **Developer Mode** on (plugin symlinks, pdfrx) |
| Linux | `clang cmake ninja-build pkg-config libgtk-3-dev` |

```bash
cd flutter_app
flutter pub get
flutter_rust_bridge_codegen generate   # only after changing rust_engine/src/api
flutter run -d windows                 # or: -d <android-device-id>, -d linux
```

Tests:

```bash
cd rust_engine && cargo test                                  # 62 engine unit tests
cd flutter_app && flutter test                                # viewport/paging, library, toolbar snapping
cd flutter_app && flutter test integration_test -d windows    # end-to-end through the FFI bridge
```

`pdfrx` builds a small C helper through Dart native assets. `native_toolchain_c` ≥ 0.19.6 is needed when the pub cache path contains spaces (`C:\Users\First Last\...`); the lock file pins it.

## Not in this prototype

Undo/redo, deleting or reordering pages, password-protected PDFs, keeping links/annotations of imported PDFs in the export, and shapes other than rectangles.
