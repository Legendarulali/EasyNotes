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
        ├── widgets/                draggable_toolbar.dart, canvas_status_bar.dart, editor_app_bar.dart,
        │                           sync_widgets.dart (account button, backup status chip)
        └── src/
            ├── editor/             EditorController (engine calls, open/autosave), tools
            ├── canvas/             NoteCanvas (input), painters (pages, PDF layer, ink), viewport, scene cache
            ├── services/           library (folders/notebooks on disk), PDF rasteriser (pdfrx), export/share
            ├── sync/               Google sign-in (google_auth, session_store), Drive backup
            │                       (backup_engine, drive_remote), SyncService (timer, status, triggers)
            ├── ui/                 hex colour picker, selection actions, sticky-note editor
            └── rust/               generated bindings (do not edit)
```

## Features

- **Library.** The app starts on a dark `#1E1E1E` dashboard.
  - The **New** menu creates a *Ruled Notebook*, a *Grid Notebook*, a *Blank Whiteboard* or a *New Folder*. **Import PDF…** creates an annotation notebook.
  - Each card has *Rename*, *Move to…* and *Delete*, via the ⋮ button, a long press or a right-click.
  - Notebooks autosave, and their card shows a thumbnail of the first page.
- **Pages.** Notebook pages are exactly 1000 × 1000 units, stacked with no gap (page *n* spans y ∈ [1000·n, 1000·(n+1))).
  - **Continuous pages.** Any downward scroll (touch, trackpad, pinch, mouse wheel) that brings the bottom of the view within 50 units of the end of the last page (`Y ≥ N·1000 − 50`) appends page N+1 directly beneath it, one page per scroll step.
  - The pen does the same: writing into the last 50 units of the last page opens the next page under it.
  - Content that reaches below the last page, such as a stroke, a moved selection or a pasted item, appends pages to fit.
  - Blank pages created only by scrolling are dropped when the notebook is closed. Pages with ink or notes, everything above them, and imported PDF pages always stay.
  - Ink and notes are kept inside the 1000-unit page column. Whiteboards are unbounded towards +X / +Y.
- **No content under the toolbar.** The canvas keeps the band covered by a docked toolbar free at the scroll limits.
  - With the toolbar docked at the top, page 1 rests 80 px down, just below it.
  - With a side dock, the page is centred in the remaining width.
  - World `y = 0` is still the top edge of page 1, so stroke coordinates are unaffected.
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
- **Status bar.** Shows:
  - zoom;
  - the pan offsets (`X`/`Y` = world point at the top-left of the free canvas area, `0 0` at the top of page 1);
  - `Page X / Y`, which updates live while scrolling and as pages are appended;
  - a tool hint;
  - the backup status (*Synced*, *Syncing…*, *Pending*, *Offline*, *Local only*).

  Tapping the bar (or Ctrl+0) **only** resets the zoom to 100%. The vertical offset is kept, and so is the horizontal one unless the whole page width fits at 100%, in which case the page is centred.
- **Google account & Drive backup.** "Sign in with Google" sits in the top-right corner of the library. Once signed in, the avatar shows the backup status, and its menu offers *Back up now* and *Sign out*.
  - Saving stays local and instant, exactly as before.
  - The library is pushed to `My Drive › EasyNotes/` in the background:
    - every 3 minutes;
    - when a notebook is closed;
    - after rename / move / delete;
    - when the app is hidden;
    - before a desktop window closes (bounded to 15 s, after open notebooks save).
  - Uploads are incremental. With no local changes, a run makes no network requests. Changed files are MD5-compared before uploading, renames and moves become Drive moves, and deletes go to the Drive trash (recoverable for 30 days).
  - An interrupted run resumes where it stopped. After a reinstall, the existing backup is adopted instead of duplicated.
  - Scope is `drive.file`: the app can only see files it created, nothing else in your Drive.
  - The backup mirrors the library's folder structure, so a notebook can be restored by downloading its `Name.enote` folder into `Documents/EasyNotes`.
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
| Mouse | Left button draws. Right/middle drag pans. Wheel scrolls (Shift = horizontal; reaching the end of the last page appends one); Ctrl+wheel zooms. Trackpad pinch zooms. |
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

### Google sign-in and Drive backup (optional)

Without OAuth client ids the app works fully offline: the account button explains that backup isn't set up, and the status bar shows *Local only*. To enable it:

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and enable the **Google Drive API**.
2. Configure the **OAuth consent screen** with the scope `.../auth/drive.file`. It is non-sensitive, so no verification is needed. While the app is in *Testing*, add yourself as a test user.
3. Create the OAuth clients you need:

   | Platform | Client type | Goes into |
   |---|---|---|
   | Windows / Linux | *Desktop app* | `GOOGLE_DESKTOP_CLIENT_ID`, `GOOGLE_DESKTOP_CLIENT_SECRET` |
   | Android | *Android* (package `com.easynotes.flutter_app` + your signing SHA-1) **and** a *Web application* client | the web client id → `GOOGLE_SERVER_CLIENT_ID` |
   | iOS | *iOS* (bundle id `com.easynotes.flutterApp`) | `GOOGLE_IOS_CLIENT_ID`, plus its reversed id as a `CFBundleURLSchemes` entry in `ios/Runner/Info.plist` |

4. Copy `flutter_app/google_oauth.example.json` to `flutter_app/google_oauth.json`, which is git-ignored, and fill it in. Then run:

   ```bash
   flutter run -d windows --dart-define-from-file=google_oauth.json
   ```

How the sign-in works on each platform:

- **Windows and Linux.** `google_sign_in` has no desktop support, so the app opens the system browser and receives the redirect on a one-shot `localhost` server (state check + PKCE).
- **Where the session is kept.** The session (refresh token) is stored in the app-support folder. On Windows it is encrypted with DPAPI for the current user; on Linux it is an owner-only file.
- **Android, iOS and macOS.** These use `google_sign_in`, which keeps the session itself.
- **Backup bookkeeping.** The backup state lives in `Documents/EasyNotes/.backup-state.json`.

Tests:

```bash
cd rust_engine && cargo test                                  # 66 engine unit tests
cd flutter_app && flutter test                                # viewport/paging (bugs A/B), library, toolbar, Drive backup + sync (fake Drive)
cd flutter_app && flutter test integration_test -d windows    # end-to-end through the FFI bridge, incl. the editor
```

`pdfrx` builds a small C helper through Dart native assets. `native_toolchain_c` ≥ 0.19.6 is needed when the pub cache path contains spaces (`C:\Users\First Last\...`); the lock file pins it.

## Not in this prototype

This prototype does not include:

- undo/redo;
- deleting or reordering pages (other than the automatic trim of unused trailing pages);
- password-protected PDFs;
- keeping links/annotations of imported PDFs in the export;
- shapes other than rectangles;
- restoring from Drive inside the app (download the `.enote` folder instead);
- two-way sync between devices. The backup is push-only: several devices can back up into the same `EasyNotes/` folder, but each one only uploads, moves and trashes its own notebooks.
