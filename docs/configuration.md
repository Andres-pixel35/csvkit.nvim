# Configuration

Calling `setup()` is **optional**. Without it, every option below has its default value and `.csv` files are picked up automatically. Pass only the options you want to change; the rest keep their defaults.

```lua
require("csvkit").setup({
  decimal = ",",                       -- only what differs from the defaults
  view = { max_col_width = 40 },
})
```

With lazy.nvim, put the same table in `opts = { ... }` instead of calling `setup()` yourself.

## All options and their defaults

```lua
require("csvkit").setup({
  extensions = { "csv" },              -- file extensions csvkit attaches to
  delimiter = "auto",                  -- "auto" | "," | ";" | "\t" | "|"
  header = true,                       -- the first row holds the column names
  decimal = "auto",                    -- "auto" | "." | ","
  thousands = "auto",                  -- "auto" | false | "," | "." | " " | "'"
  date_formats = {                     -- tried in this order
    "%Y-%m-%d",
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S",
    "%d/%m/%Y",
  },
  align = {
    enabled = true,                    -- align columns when a file opens
    separator = "│",                   -- drawn in place of the delimiter
    sticky_header = true,              -- keep the header row at the top of the window
  },
  view = {
    max_col_width = 0,                 -- 0 = no limit, or the widest a column may be (characters)
  },
  preview = {
    port = 0,                          -- 0 = any free port
    debounce_ms = 300,                 -- wait after the last edit before refreshing the page
    live_update_max_mb = 2,            -- bigger files refresh the page on :w only
  },
  restore = {
    mode = "buffer",                   -- what :Csvkit restore does with no argument
    backup = true,                     -- keep a copy of each file as it was opened
  },
  memory = {
    trim = false,                      -- give memory back to the system after big edits
  },
  formula = {
    prev_default = 0,                  -- PREV's value when the row it reads is empty or missing
  },
})
```

## What each option does

### `extensions`

<details>
<summary>Show details</summary>

**Default:** `{ "csv" }`

The file extensions csvkit turns itself on for. To also handle tab- and pipe-separated files:

```lua
extensions = { "csv", "tsv", "psv" }
```

> [!IMPORTANT]
> With lazy.nvim, the plugin is only loaded for the filetypes in its `ft` list. If you add extensions here, add them to `ft` too (`ft = { "csv", "tsv" }`), or opening a `.tsv` file will not load csvkit. See [Why `ft` must match](#why-ft-must-match-extensions).

</details>

### `delimiter`

**Default:** `"auto"` · **Values:** `"auto"`, `","`, `";"`, `"\t"` (tab), `"|"`

The character that separates the fields of a row. With `"auto"`, csvkit looks at the first 20 lines and picks the first of `,` `;` tab `|` that splits every row into the same number of fields (more than one). If none does, it uses `,`.

Set it yourself when detection guesses wrong. That can happen, for example, in a `;`-separated file where every row also has the same number of commas: `,` is tried first and wins.

### `header`

<details>
<summary>Show details</summary>

**Default:** `true`

Whether the first row holds the column names. Set it to `false` for files with no header row. Then:
- columns can only be referred to by number (`$0`, `$1`, ... in formulas; `0`, `1`, ... in commands),
- the first row is sorted, filtered and edited like any other row,
- the sticky header is not shown.

</details>

### `decimal` and `thousands`

<details>
<summary>Show details</summary>

**Defaults:** `"auto"` and `"auto"`

How numbers are written in the file:

| Option | Values | Meaning |
|---|---|---|
| `decimal` | `"auto"`, `"."`, `","` | The character before the decimals: `3.5` or `3,5` |
| `thousands` | `"auto"`, `false`, `","`, `"."`, `" "`, `"'"` | The character between groups of thousands: `1,234,567`. `false` means none |

With `"auto"`, csvkit tries every combination on the first 100 lines and keeps the one that reads the most cells as numbers. When two combinations tie, the simpler one wins, so a file with no decimals at all gets `"."` and no thousands separator.

These settings decide what counts as a number when sorting, filtering and computing formulas. They never change how a formula is **written**: formulas always use `.` for decimals (`price * 1.19`), whatever the file uses. Results are written back with the file's decimal separator.

To fix the detection for one file without touching your config, use `:Csvkit decimal ,` or `:Csvkit thousands .` (see [Per-file settings](#per-file-settings)).

</details>

### `date_formats`

<details>
<summary>Show details</summary>

**Default:** `{ "%Y-%m-%d", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%d/%m/%Y" }`

The date formats csvkit recognises, so that dates sort by date (not as text) and work in formulas. Each format is built from these codes:

| Code | Meaning | Example |
|---|---|---|
| `%Y` | year, 4 digits | `2024` |
| `%m` | month, 1 or 2 digits | `3`, `03` |
| `%d` | day, 1 or 2 digits | `7`, `07` |
| `%H` `%M` `%S` | hours, minutes, seconds | `14:05:00` |

Any other character must appear as it is (`-`, `/`, `T`, a space). Every format needs `%Y`, `%m` and `%d`.

- Formats are tried **in order**, and a cell is a date only if it is a real calendar date (`2024-02-29` is, `2023-02-29` is not).
- The **first** format is also the one `TODAY()` and `DATE()` write their results in.
- For month-first files (`03/31/2024`), replace `"%d/%m/%Y"` with `"%m/%d/%Y"`. Keep only one of the two: a date like `03/04/2024` fits both, and the first match wins.

Setting `date_formats` replaces the whole list; it is not merged with the default one.

</details>

### `align`

<details>
<summary>Show details</summary>

The [aligned overlay](views.md#aligned-overlay): padding drawn over the real file so its columns line up. The file's text itself is never changed.

| Option | Default | Meaning |
|---|---|---|
| `align.enabled` | `true` | Align every matching file as soon as it opens. With `false`, files open as plain text; `:Csvkit align on` aligns one when you want it |
| `align.separator` | `"│"` | What is drawn in place of each delimiter. Any string, e.g. `"|"` |
| `align.sticky_header` | `true` | Show the header row in the window's top bar (`winbar`), so the column names stay visible while you scroll. Needs `header = true` |

</details>

### `view.max_col_width`

<details>
<summary>Show details</summary>

**Default:** `0` · **Values:** `0`, or a positive whole number

The widest a column can be, in characters. It applies to both the [table view](views.md#table-view) and the [browser preview](views.md#browser-preview). (The [aligned overlay](views.md#aligned-overlay) never cuts cells: it shows the file's own text.)

- `0`: no limit. Each column is as wide as its widest cell, so nothing is ever cut. Long text makes wide columns.
- A positive whole number, e.g. `30`: longer cells are cut to that many characters and end with `…`. Only the display is cut; the cell's text in the file stays complete.

Any other value (`-1`, `2.5`, `false`, `"30"`) is refused: `:Csvkit view` and `:Csvkit preview` show an error naming the option instead of opening.

</details>

### `preview`

<details>
<summary>Show details</summary>

The [browser preview](views.md#browser-preview), a read-only page that shows the file in your browser and follows your edits.

| Option | Default | Meaning |
|---|---|---|
| `preview.port` | `0` | The local port the page is served on. `0` picks any free port each time. Set a number such as `8765` to keep the same address; `:Csvkit preview` fails with a message if that port is in use |
| `preview.debounce_ms` | `300` | How long to wait, in milliseconds, after your **last** edit before the page reloads. While you keep typing nothing is sent; 300 ms after you stop, the page refreshes once. Lower is snappier, higher does less work |
| `preview.live_update_max_mb` | `2` | Files larger than this (in megabytes) do not refresh on every edit, because rebuilding the page's data pauses Neovim (about 0.25 s at 2 MB). They refresh when you save with `:w`. `false` refreshes on every edit whatever the size |

</details>

### `restore`

<details>
<summary>Show details</summary>

When a file opens, csvkit keeps a copy of it on disk so that [`:Csvkit restore`](commands.md#restore) can bring it back later, even after you saved changes.

| Option | Default | Meaning |
|---|---|---|
| `restore.mode` | `"buffer"` | What `:Csvkit restore` does when you give it no argument. `"buffer"`: put the original text back into the buffer as one edit you can undo; the file changes when you `:w`. `"file"`: put the copy back over the file on disk and reload the buffer (undo history is lost; you are asked first if anything would be lost) |
| `restore.backup` | `true` | Make the copy at all. With `false`, opening a file does no extra disk work, but `:Csvkit restore` has nothing to restore |

Copies are kept in `stdpath("state")/csvkit/backup/` (on Linux, `~/.local/state/nvim/csvkit/backup/`), in a folder only you can read. Each copy is deleted when its buffer is closed (`:bdelete`, `:bwipeout`) or when Neovim exits.

</details>

### `memory.trim`

**Default:** `false`

Big edits (sorting or adding a column to a large file) free a lot of memory, but the system's memory allocator usually keeps it reserved for Neovim. With `true`, after an edit that rewrote more than 10,000 lines, csvkit asks the allocator to give that memory back to the operating system.

It costs a pause of about 0.6 s on a 1-million-row file, which is why it is off. It only has an effect on Linux with glibc; elsewhere it does nothing.

### `formula.prev_default`

<details>
<summary>Show details</summary>

**Default:** `0` · **Values:** a number, or a text

What [`PREV`](formulas.md#prev-the-row-before) gives when the row it reads has an empty cell, or there is no such row (the first row). With the default, `total - PREV(total)` on the first row is `total - 0`.

- A number is used as it is: `prev_default = -1`.
- A text is read like a cell: `"-1"` is the number -1, `"2024-01-01"` a date (when it matches `date_formats`), `"n/a"` or `"好"` text, and `""` an empty value. With `""`, arithmetic with an empty `PREV` fails and that row's cell is left empty.
- Anything else (`true`, a table) is refused: the command stops with an error naming the option.

</details>

## Per-file settings

<details>
<summary>Show details</summary>

Options can come from three places. When they disagree, the later one wins:

1. `setup()`: your configuration, for every file.
2. **Remembered for this file**: what you set with `:Csvkit decimal` or `:Csvkit thousands`. Stored in `stdpath("data")/csvkit/files.json` by the file's full path, so it applies every time you open that file. `:Csvkit decimal auto` goes back to detection.
3. `vim.b.csvkit`: a buffer variable, for settings decided by your own code. For example, every CSV under a work folder uses `;` and decimal commas:

```lua
vim.api.nvim_create_autocmd("BufReadPre", {
  pattern = "*/work/*.csv",
  callback = function(ev)
    vim.b[ev.buf].csvkit = { delimiter = ";", decimal = ",", thousands = "." }
  end,
})
```

Whatever is still `"auto"` after these three is detected from the file.

</details>

## Value types

<details>
<summary>Show details</summary>

csvkit decides the type of each cell from its text, with spaces at both ends ignored. It never changes the cell; the type only matters for sorting, filtering and formulas.

| Type | Rule | Examples |
|---|---|---|
| empty | Nothing but spaces | ` ` |
| number | Optional sign, digits, optional decimals, optional exponent, written with the file's `decimal` (and `thousands`, if set) | `42`, `-3.5`, `.5`, `5.`, `1e3`, `007` |
| date | Matches one of `date_formats` **and** is a real calendar date | `2024-02-29`, `31/12/2024` |
| bool | `true` or `false`, any case | `TRUE`, `False` |
| text | Anything else | `abc`, `0x1A`, `inf`, `1.2.3` |

Things that are deliberately **not** numbers: hexadecimal (`0x1A`), `inf`, `nan`, currency (`$1,234`) and percentages (`45%`). With a thousands separator set, every group after the first must have exactly 3 digits: with `decimal = ","` and `thousands = "."`, `1.234,56` is a number but `1.5` is not.

**A column's type**, used for sorting, is the type all of its non-empty cells share. If even one non-empty cell differs, the column sorts as text. `:Csvkit sort price num` forces a type.

</details>

## Why `ft` must match `extensions`

To keep startup fast, csvkit loads almost nothing until it is needed: at startup it only defines the `:Csvkit` command and a rule that attaches to `*.csv` files. When `setup()` runs, it replaces that rule with one for your `extensions`, and also attaches to matching files that are already open (a plugin manager may load csvkit after the first file was read).

With lazy.nvim, `ft = { "csv" }` means "load csvkit when a `csv` buffer opens". If you add `"tsv"` to `extensions` but not to `ft`, opening a `.tsv` file first never loads csvkit, so nothing happens.
