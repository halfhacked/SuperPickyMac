# Culling Streamline — Design Spec

Streamline the path from AI-powered culling to Lightroom import. Two themes: (A) Lightroom-ready export pipeline, (B) culling workflow improvements.

## A: Lightroom-Ready Pipeline

### A1. Minimum Star Filter Bar

Secondary filter above the thumbnail strip. "Show ≥ N stars" stepper (0–5, default 0 = show all).

- Applies on top of the current sidebar selection (species, burst, flying, etc.)
- Resets to 0 when sidebar selection changes
- Keyboard: Cmd+1–5 sets minimum, Cmd+0 resets (plain 1–5 remains "rate photo")
- Photo count indicator updates: "8 of 26"

### A2. One-Click Export Picks

Replaces current NSOpenPanel export. Exports all `isPick` photos from the current folder.

- Destination: `<folder>-picks/` subfolder next to source (e.g. `birds/` → `birds-picks/`)
- Copies RAW + XMP sidecar. Skips already-exported files.
- Trigger: toolbar "Export Picks" button + Cmd+E shortcut
- No dialog. If zero picks: alert "No picks to export."
- After export: alert with count + "Reveal in Finder" button
- Removes old NSOpenPanel export flow

### A3. Pick Flag in XMP

Write `xmp:PickStatus` attribute so Lightroom recognizes flagged photos on import.

- `xmp:PickStatus="1"` for picked photos, `"0"` for unpicked
- Always written (not just for picks), so LR sees correct state regardless

### A4. Auto-Write XMP Sidecars on Processing

Don't wait for export — write XMP sidecars immediately after each photo is processed.

- Ensures sidecars stay in sync with DB state
- Export just copies existing sidecars (already up to date)
- Re-write sidecar when rating/pick changes manually

### A5. Export Complete → Reveal in Finder

After export completes, alert includes "Reveal in Finder" button.

- Opens the `<folder>-picks/` subfolder in Finder
- Exported N photos, skipped M (already exported)

### A6. Export Keyboard Shortcut

Cmd+E triggers Export Picks (same as toolbar button).

## B: Culling Workflow Improvements

### B7. Compare Mode

Side-by-side view of 2 photos for burst review.

- Enter with `C` key — shows selected photo + next photo
- Arrow keys swap the right-side photo through the sequence
- Rate/pick either side independently
- Exit with `C` or Escape

### B8. Auto-Advance After Rating

After pressing 1–5 or P, automatically advance to the next photo.

- Configurable toggle in settings (default: off)
- When on, rating or picking moves selection to next photo in current filtered view
- Does not advance if already at the last photo

### B9. Reject and Hide

Press `X` to mark as reject (rating 0) and immediately hide from current view.

- Sets `starRating = 0` and hides photo from current filtered view
- Photo is still accessible via the "Reject (0)" sidebar filter
- Undo via Cmd+Z (see B10)

### B10. Undo Last Action

Cmd+Z undoes the last rating, pick, or reject action.

- Single-level undo (last action only)
- Restores previous rating/pick state and re-shows photo if it was hidden

### B11. Photo Counter

"3 of 12" indicator showing position in the current filtered view.

- Displayed in the info bar area
- Updates on navigation and filtering

### B12. Burst Best Indicator

Visual marker on the burst-best thumbnail.

- Small crown/trophy icon on the thumbnail, similar to the pick flag position but bottom-right
- Only shown in burst group views

### B13. Quick Species Reassign

When a burst is misclassified, reassign species for all photos in the burst at once.

- Context menu on burst group in sidebar: "Reassign Species"
- Shows picker with detected species from the folder
- Updates all photos in the burst group
