# Performance and limits

> [!IMPORTANT]
> **Target: files under about 100 MB.** csvkit is for quick viewing, filtering and imputation. For bigger files use Excel or pandas. The numbers below for huge files are a record of the limits, **not promises**.

> [!NOTE]
> Not about speed, but a limit worth knowing: rows with a line break inside a cell are not aligned in the file's buffer (Neovim can't show several lines as one). `:Csvkit view` shows them on one line. See [Views](views.md#aligned-overlay).

## What to expect on a typical file

Measured on a laptop (AMD Ryzen 5 7520U) with Neovim 0.12.6, one run each, so expect ±15 to ±25 %. Each command ran in a fresh Neovim with the cursor in the middle of the file. The time includes reading and writing the buffer.

| File | `:edit` | `row add` | `sort` by number | `sort` by text | `addcol` formula |
|---|---|---|---|---|---|
| 10k rows × 10 cols (1 MB) | 12 ms | 10 ms | 26 ms | 17 ms | 35 ms |
| 100k rows × 10 cols (8 MB) | 39 ms | 44 ms | 247 ms | 182 ms | 408 ms |
| 100k rows × 25 cols (20 MB) | 75 ms | 105 ms | 339 ms | 278 ms | 553 ms |
| 100k rows × 100 cols (81 MB) | 306 ms | 245 ms | 1.29 s | 1.12 s | 1.82 s |

Other typical timings (100k rows):

| Operation | Time |
|---|---|
| Aligned overlay, first paint | 50–70 ms (about 280 ms at 1M rows) |
| Scrolling redraw | about 2 ms |
| Table view, open / sort / filter | about 150 / 120 / 120 ms |
| Table view, edit a cell / add a row / stage a column | about 20–30 ms each |
| Filter apply (folds) | 120 to 200 ms |
| Browser preview, load | 1.2–1.3 s |
| Browser sort (number / text) / filter menu | 70 / 50 ms / 30–130 ms |

## Every feature

Medians of three runs. Files from `tests/bench/gen.lua`: 100k × 10 columns (8 MB) and 1M × 10 (82 MB). Each feature runs in its own process; "peak memory" is that process's peak resident memory, buffer included. The whole system was kept under 75 % of its RAM: a run that needed more was stopped and is marked "over the cap" (the 1M browser runs need Neovim building the payload plus Firefox parsing 136 MB of JSON). Small browser times vary by ±30 % from run to run.

<details>
<summary><b>All the tables</b></summary>

**`:edit`**

| step | 100k rows | 1M rows |
|---|---|---|
| peak memory (process) | 24 MB | 105 MB |

**`:Csvkit row add`**

| step | 100k rows | 1M rows |
|---|---|---|
| time | 69 ms | 566 ms |
| peak memory (process) | 28 MB | 109 MB |

**`:Csvkit sort price`**

| step | 100k rows | 1M rows |
|---|---|---|
| time | 290 ms | 4.07 s |
| peak memory (process) | 79 MB | 657 MB |

**`:Csvkit sort name desc`**

| step | 100k rows | 1M rows |
|---|---|---|
| time | 218 ms | 2.85 s |
| peak memory (process) | 77 MB | 623 MB |

**`:Csvkit addcol total formula price * qty + 1`**

| step | 100k rows | 1M rows |
|---|---|---|
| time | 455 ms | 6.71 s |
| peak memory (process) | 106 MB | 873 MB |

**`:Csvkit addcol tag value x`**

| step | 100k rows | 1M rows |
|---|---|---|
| time | 279 ms | 3.31 s |
| peak memory (process) | 85 MB | 765 MB |

**Aligned overlay**

| step | 100k rows | 1M rows |
|---|---|---|
| first paint | 66 ms | 285 ms |
| first scan done | 310 ms | 3.19 s |
| redraw (one screen) | 2.5 ms | 2.8 ms |
| on_lines | 0.1 ms | 0.1 ms |
| widths grown | 100 ms | 99 ms |
| re-scan done | 310 ms | 2.46 s |
| peak memory (process) | 28 MB | 109 MB |

**Table view (`:Csvkit view`)**

| step | 100k rows | 1M rows |
|---|---|---|
| open | 152 ms | 1.16 s |
| scroll to the end | 1.0 ms | 2.0 ms |
| sort price (number) | 121 ms | 1.13 s |
| sort name (text) | 54 ms | 324 ms |
| sort price desc | 112 ms | 1.10 s |
| filter flag = true | 120 ms | 1.08 s |
| edit a cell (first edit) | 23 ms | 35 ms |
| edit a cell | 22 ms | 25 ms |
| edit a cell in the sorted column | 88 ms | 808 ms |
| row add | 24 ms | 30 ms |
| addcol value | 26 ms | 34 ms |
| addcol formula price * qty + 1 | 164 ms | 1.42 s |
| apply sort (edits + order) | 488 ms | 6.15 s |
| discard | 55 ms | 278 ms |
| follow a source edit (no debounce) | 90 ms | 645 ms |
| peak memory (process) | 127 MB | 1119 MB |

**Filter in the source buffer**

| step | 100k rows | 1M rows |
|---|---|---|
| filter flag = true (folds) | 191 ms | 1.85 s |
| filter qty blank (AND) | 118 ms | 1.32 s |
| filter clear | 0.0 ms | 0.0 ms |
| picker open: city (5 values) | 47 ms | 525 ms |
| picker open: id (all distinct) | 234 ms | 2.66 s |
| picker: toggle all (a) | 36 ms | 396 ms |
| peak memory (process) | 78 MB | 620 MB |

**`:Csvkit restore buffer` (after a sort, `:w` and an edit)**

| step | 100k rows | 1M rows |
|---|---|---|
| time | 171 ms | 2.42 s |
| peak memory (process) | 80 MB | 693 MB |

**`:Csvkit restore file` (same state)**

| step | 100k rows | 1M rows |
|---|---|---|
| time | 29 ms | 203 ms |
| peak memory (process) | 78 MB | 657 MB |

**Browser preview: building `/data` in Neovim**

| step | 100k rows | 1M rows |
|---|---|---|
| payload | 677 ms | 7.12 s |
| vim.json.encode | 264 ms | 2.72 s |
| JSON MB | 13 MB | 136 MB |
| GET /data (payload + JSON + send) | 863 ms | 9.38 s |
| peak memory (process) | 99 MB | 744 MB |

**Browser page (headless Firefox 158)**

| step | 100k rows | 1M rows |
|---|---|---|
| load (until the rows are drawn) | 1.24 s | over the cap |
| JSON MB | 13 MB | over the cap |
| Firefox memory after load | 35 MB | over the cap |
| sort price (number) | 71 ms | over the cap |
| sort price desc | 67 ms | over the cap |
| sort off | 31 ms | over the cap |
| sort name (text) | 46 ms | over the cap |
| sort memo (text, unique-ish) | 44 ms | over the cap |
| filter menu: flag | 30 ms | over the cap |
| filter: uncheck one value | 31 ms | over the cap |
| filter menu: id (all distinct) | 132 ms | over the cap |
| filter menu: search '12' | 40 ms | over the cap |
| clear filters | 34 ms | over the cap |
| scroll to the end | 28 ms | over the cap |
| reload (fetch + parse + draw) | 946 ms | over the cap |
| Firefox memory at the end | 48 MB | over the cap |

</details>

<details>
<summary><b>Beyond 100 MB (known limits)</b></summary>

| File | `:edit` | `sort` by number | `addcol` formula | Peak memory (sort) |
|---|---|---|---|---|
| 1M rows × 5 cols (33 MB) | 211 ms | 3.7 s | 5.3 s | 394 MB |
| 1M rows × 10 cols (82 MB) | 245 ms | 3.7 s | 8.3 s | 657 MB |
| 1M rows × 25 cols (203 MB) | 532 ms | 4.8 s | 6.6 s | 1.2 GB |
| 1M rows × 50 cols (412 MB) | 1.06 s | 7.2 s | 9.6 s | 2.3 GB |
| 1M rows × 100 cols (824 MB) | 2.21 s | 10.7 s | 14.5 s | 4.7 GB |

Memory grows with the size of the file because commands read the columns they need and Neovim keeps the old text of replaced lines for undo.

Known limits for huge files, deliberately not worked on:

- **Browser preview:** at 1M rows Neovim takes about 8.5 s to build and send `/data` (136 MB of JSON), and Neovim is busy meanwhile. The page itself was not measured at 1M (over the memory cap of the benchmark machine). The filter list shows 500 values.
- **Table view:** above 5000 rows `/` finds only rows already drawn.
- **Overlay:** the full width scan takes about 2 s at 1M rows, in the background.
- **Wide files:** the preview payload is built from all columns; there is no "send only visible columns" mode.

</details>

<details>
<summary><b>Why it is fast</b></summary>

- **No full parse.** Commands first note where each row starts, then read only the columns they need, instead of splitting every row into fields.
- **Original text is kept.** Sort moves raw lines, and `addcol` inserts the new field into each record's text, so untouched records are never rewritten.
- **One buffer write per edit.** A single `nvim_buf_set_lines` call, which is also one undo step.
- **Only the visible part is drawn.** The overlay decorates visible lines, the table view fills rows as they approach the window, and the browser renders a virtual slice.
- **A sort written in Lua** (a stable merge sort) instead of Lua's built-in `table.sort`, because Neovim's Lua compiler can optimise the former but not the latter.
- **The table view does only what changed.** Staging does not copy the rows (a row nothing was done to is just its row number); the order is worked out again only when the sort, a filter or a sorted cell changes; a new row is put in place without sorting; following the source reads only the lines that changed.
- **The browser sorts distinct values, not rows.** Each different value is sorted once, then the rows are placed by their value's position, instead of comparing rows pair by pair.

</details>

<details>
<summary><b>Memory and undo</b></summary>

- Every command is one undo step. Commands other than `row add` replace lines, and Neovim keeps the old text of replaced lines for undo (about 85 MB per sort at 1M rows), so only the 3 most recent of them stay undoable. Your own edits before the oldest of those three can't be undone either; `:Csvkit restore` still brings back the file as it was opened.
- The backup copy lives on disk under `stdpath("state")`, not in RAM or `/tmp`.
- `memory.trim = true` gives freed memory back to the OS after big edits (Neovim's memory use went from 619 to 372 MB after a sort at 1M rows, at the cost of a 0.6 s pause). See [Configuration](configuration.md#memorytrim).

</details>

## Reproducing the numbers

```sh
nvim --headless --clean -l tests/bench/gen.lua 1000000 10     # writes .bench/ (never committed)
nvim --headless --clean -l tests/bench/run.lua 1000000x10     # core stages
nvim --headless --clean -l tests/bench/run.lua 1000000x10 "sort price"
bash tests/bench/matrix.sh                                    # rows x columns matrix
nvim --headless --clean -l tests/bench/features.lua 100000x10 view   # or filter, restore, restore_file, preview
node tests/bench/browser.js 100000x10                         # the browser page, in headless Firefox
```
