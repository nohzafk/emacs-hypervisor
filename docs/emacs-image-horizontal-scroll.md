# Why Emacs Cannot Horizontally Scroll Large Images

**Attention Conservation Notice.** This documents a confirmed limitation in
Emacs's display engine as of version 30.2 on the macOS NS port. If you've
ever zoomed into an image in `image-mode` and wondered why you can scroll
vertically but not horizontally — this is why, and there is no workaround.

## The Problem

Open a large SVG diagram in `image-mode`. Zoom in with `+`. The image is
now wider than your window. You can scroll vertically with arrow keys or
touchpad — no issues. Try scrolling horizontally to see the right side of the
image. Nothing happens. There is no key, no function, and no configuration
that makes horizontal panning work.

This isn't a keybinding oversight. It's a gap in Emacs's C display engine.

## Root Cause: An Asymmetry in the Display Engine

Emacs provides two low-level primitives for shifting a window's viewport:

```elisp
;; Vertical — has a pixel-precise mode (the t third argument)
(set-window-vscroll WINDOW PIXELS t)

;; Horizontal — character columns only, no pixel equivalent
(set-window-hscroll WINDOW COLUMNS)
```

`set-window-vscroll` accepts pixel offsets. When `image-next-line` scrolls an
image downward, it computes a pixel delta from `frame-char-height`, adds it to
the current vscroll, and calls `set-window-vscroll` with the `t` flag. The
display engine shifts the viewport by exactly that many pixels. This is why
`j`/`k` and touchpad vertical scrolling work.

`set-window-hscroll` has **no pixel mode**. It takes a column count — the
number of character-width units to skip at the left edge of the window. For
text buffers this is fine: "skip 10 columns" means "hide the first 10
characters." For an image displayed as a single `display` text property,
"skip 10 columns" is meaningless. The display engine has no way to say "render
this image starting from pixel X."

## What We Tried

### 1. `image-forward-hscroll` / `set-window-hscroll`

The built-in `image-forward-hscroll` function computes an image width in
character columns and calls `set-window-hscroll`. On the macOS NS port, this
has zero visible effect on the displayed image. The function runs, the hscroll
value changes, but the image doesn't move.

### 2. Disabling `auto-hscroll-mode`

Emacs's `auto-hscroll-mode` makes redisplay automatically reset horizontal
scroll to keep point visible. [Bug #14567][bug-14567] identified this as one
source of interference. Disabling it buffer-locally:

```elisp
(setq-local auto-hscroll-mode nil)
(setq-local truncate-lines t)
```

This prevents redisplay from fighting the hscroll value. But since
`set-window-hscroll` itself has no effect on images, removing the interference
doesn't help.

### 3. Image `:crop` Property

Emacs 29+ supports a `:crop` image descriptor property that selects a
sub-rectangle of the rendered image. The idea: crop the image to a
window-width horizontal slice at a tracked pan offset, bypassing
`set-window-hscroll` entirely.

```elisp
;; Crop to a window-width slice at pan-x offset, preserving full height
(setcdr image (plist-put (cdr image) :crop
                         (list win-w full-h pan-x 0)))
(image-flush image)
```

This approach hit two additional issues:

**`plist-put` silently discards mutations.** When a key doesn't exist in the
plist, `plist-put` returns a *new* list with the key prepended — it does not
modify the original list. The image spec pointed to by `(cdr image)` is
unchanged:

```elisp
(plist-put (cdr image) :crop '(800 1000 100 0))
;; Returns (:crop (800 1000 100 0) :type svg :data "...")
;; but (cdr image) still points to (:type svg :data "...")
```

The fix is `setcdr`:

```elisp
(setcdr image (plist-put (cdr image) :crop value))
```

**`:crop` requires native image transforms.** `image-transforms-p` returned
`nil` on our test build. SVG scaling works because `librsvg` handles `:scale`
natively during rendering. But `:crop` relies on the Emacs-side image
transform pipeline, which is apparently not available on this build. Even
after correctly mutating the image spec and flushing the render cache, the
crop had no visible effect.

## The Upstream Status

This is tracked as [Bug #14567: Scrolling of large images][bug-14567], filed
in 2013. A developer noted in the thread:

> "I don't understand how to use this, it is actually setting the number of
> columns where to start scrolling, and it seems an image has only one column?"

Another acknowledged:

> "that's a much larger project, since we lack infrastructure to scroll
> horizontally by pixels."

As of Emacs 30.2 (May 2026), the bug remains open with no fix.

## Practical Workarounds

Since horizontal panning isn't possible, the usable approach is to avoid
needing it:

| Key | Function                       | Effect                                |
|-----|--------------------------------|---------------------------------------|
| `w` | `image-transform-fit-to-width` | Scale image to fit window width       |
| `f` | `image-transform-fit-to-window`| Scale image to fit both width & height|
| `0` | `image-transform-original`     | Display at original 1:1 size          |
| `j` | `image-next-line`              | Scroll down (pixel-precise, works)    |
| `k` | `image-previous-line`          | Scroll up (pixel-precise, works)      |

Use `w` (fit-to-width) as the default viewing mode for wide diagrams. This
scales the image so the full width is always visible, and vertical scrolling
handles any overflow.

## Test Environment

- **Emacs**: 30.2, built from `main` branch (2026-05-09)
- **Port**: NS (AppKit 2575.70)
- **Platform**: macOS Darwin 24.6.0
- **Image type**: SVG rendered by `librsvg`

[bug-14567]: https://gnu.emacs.bug.narkive.com/gq2RClDe/bug-14567-scrolling-of-large-images
