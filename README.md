# Folio — an iPad PDF reader that feels like a book

Folio is a native iPadOS app (SwiftUI + UIKit + PDFKit + PencilKit) for reading PDFs the way you read paper books, and writing on them with Apple Pencil.

## Features

**Reading like a real book**
- Page curl turns pages, using the same effect as Apple Books. You can drag a corner, swipe, or tap near the edge.
- In landscape the book opens as a two-page spread. The cover sits on its own, the pages meet at a shaded spine, and the inside covers are blank endpapers.
- Pages are pre-rendered in the background, so the curl never shows a blank sheet. Pinch to zoom: tiled rendering keeps text sharp at 4×.
- A page slider at the bottom, ← → arrow buttons (and arrow keys on a keyboard), bookmarks, and the PDF's table of contents.

**Writing with Apple Pencil**
- Pen styles: ballpoint, fountain pen, monoline and pencil. Also a marker, a stroke or pixel eraser, and a lasso. Every tool comes in several colors and sizes.
- Apple Pencil writes while your finger turns pages, so you never have to switch modes. Without a pencil, turn on finger drawing.
- Double-tap or squeeze Apple Pencil to switch to the eraser or the previous tool. This follows the action you chose in iPadOS Settings.
- Each page has its own undo/redo history.

**Highlights**
- *Highlight Text*: drag across a sentence and the highlight snaps to the words. Tap a highlight to recolor it, copy its text or remove it.
- Every highlight is listed in the sidebar with the quoted text.
- For scanned books without selectable text, the freehand marker works anywhere.

**Numbered pins for handwritten notes**
- Choose the **Pin** tool, then **tap your handwriting**. Folio groups the nearby strokes into a single note and pins all of it. You can also **drag a box** around exactly the area you want.
- Each pin gets a number (1, 2, 3 …) and a colored numbered badge on the page.
- The sidebar lists every pin with its number, title, a **picture of the handwriting** and where it lives. Tap a pin to turn to that page and flash the note.
- Rename, recolor and delete pins. Drag pins into a new order, or **renumber them in page order**, and the numbers stay 1…n.

**Whiteboards**
- Each book can have any number of separate whiteboards: plain, lined, grid or dotted paper that grows as you write.
- Show the book only, the whiteboard only, or **both side by side**, so you can take notes while you read.
- Handwriting on a whiteboard can be pinned too, and those pins go in the same numbered list as the page pins.

**Export**
- Share an annotated PDF with the ink, highlights and pin numbers burned in. The whiteboards are added as pages at the end.

## Running it

Requirements: **Xcode 16 or newer** and an iPad (or the iPad simulator) on **iPadOS 17+**.

1. Open `Folio.xcodeproj`.
2. Select the **Folio** target → *Signing & Capabilities* and pick your team. You can also change the bundle id `com.example.folio`.
3. Choose your iPad (or an iPad simulator) and press **Run**.

When you first launch the app, it creates a short *Welcome to Folio* guide book. It walks through every gesture, and its last page is ruled so you can practise pinning. Import your own PDFs with **+** in the library, or open a PDF from Files, Mail or Safari and pick *Open in Folio*.

CI (`.github/workflows/ios-build.yml`) builds the app for the iPad simulator on every push.

## How it's built

```
Folio/
  App/          FolioApp: library ↔ open book, "Open in…" handling, saving on background
  Models/       Book, annotations (Highlight, Pin, Whiteboard, bookmarks), tools
  Storage/      Library folder management, per-book files, generated welcome book
  Session/      BookSession: the state of an open book (tools, ink, pins, navigation)
                + annotated PDF export and pin thumbnails
  PDF/          PageGeometry (PDF ↔ screen coordinates, page rotation),
                PageRenderer (thread-safe Core Graphics rendering, cache, tiles)
  Reader/       BookReaderViewController (UIPageViewController, page curl, spreads)
                PageViewController (one sheet: PDF + highlights + PencilKit + pins)
                NoteSurfaceViewController (shared by pages and whiteboards:
                tools, zoom, tap-to-pin, drag-to-pin, menus)
  Whiteboard/   Growing whiteboard canvas and paper patterns
  Views/        SwiftUI: library, workspace, sidebar, tool palette, page slider
```

Key design decisions:

- **Ink, highlights and pins are stored in page space.** Page space uses PDF points, with the origin at the top-left and the page's rotation applied. Annotations stay attached to the right words whatever the screen size, orientation, zoom or single/two-page layout. The PencilKit canvas zooms from the drawing space onto the screen, and the PDF and highlights sit underneath, inside the same zooming content.
- **Gesture arbitration is explicit.** The page-curl gestures accept only finger, trackpad and mouse touches. Apple Pencil gets them too, but only in Read mode. The curl gestures switch off while the Pin or Highlight Text tool is active, while finger drawing is on, and while a page is zoomed in.
- **Each book is plain files on disk:**
  ```
  Documents/Library/<book-id>/
    book.json, book.pdf, annotations.json
    ink/page-<n>.drawing      PencilKit data per page
    boards/<board-id>.drawing PencilKit data per whiteboard
  ```
  Saving is debounced and runs on a background queue. When the app leaves the foreground or a book closes, everything is flushed to disk.
