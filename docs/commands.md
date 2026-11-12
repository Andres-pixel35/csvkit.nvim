# Commands

Everything is done with one command, `:Csvkit`, followed by a subcommand: `:Csvkit sort price`. Press `<Tab>` after `:Csvkit ` to complete subcommands, options and column names.

## How to read this page

<details>
<summary>Show the notation</summary>

| Notation | Meaning |
|---|---|
| `{col}` | A column (see [Naming a column](#naming-a-column)) |
| `{expr}` | A [formula](formulas.md), e.g. `price * qty` |
| `[...]` | Optional: can be left out |
| `a\|b` | One of the choices: `a` or `b` |
| `...` | Can be repeated: `delcol 2 5 7` |

Most commands work in two places, and do slightly different things in each:

- **The file's buffer**: the CSV file you opened. Commands change it directly. Each command is a single edit, so one `u` undoes it, and `:w` saves it.
- **The [table view](views.md#table-view)**: a separate buffer opened with `:Csvkit view`. Commands there are **staged**: you see the result right away, but the file changes only when you run `:Csvkit apply`.

</details>

## Naming a column

<details>
<summary>Show how</summary>

Wherever a command takes `{col}`, you can write:

| You write | It means |
|---|---|
| `price` | The column whose header is `price` |
| `unit\ price` | A header with a space: put `\` before the space |
| `3` | Column number 3. **Numbers count from 0**: `0` is the first column, `3` the fourth |
| `-1` | Counting from the end: `-1` is the last column, `-2` the one before it |
| *(nothing)* | The column under the cursor |

You don't have to count: the sticky header, the table view and the browser show each column's number before its name (`0 date │ 1 price │ 2 qty`).

Commands that take several columns (`delcol`, `hide`) also take **ranges**, `a-b`, both ends included: `2-5` is columns 2, 3, 4 and 5. Either end can be negative: `2--1` is from column 2 to the last one, `-3--1` the last three.

</details>

## All commands

| Command | In the file's buffer | In the table view |
|---|---|---|
| [`sort [{col}] [asc\|desc] [num\|str\|date]`](#sort) | Sorts the rows | Sorts the view only |
| [`filter [{col}]`](#filter) | Hides rows whose value you untick | Same, in the view |
| [`filter {expr}`](#filter) | Hides rows where the formula is not TRUE | Same, in the view |
| [`filter clear`](#filter) | Shows every row again | Same |
| [`row add [above\|below]`](#row-add) | Inserts an empty row | Staged |
| [`row delete`](#row-delete) | Deletes the row under the cursor (or a range) | Staged |
| [`row delete where {expr}`](#row-delete) | Deletes the rows where the formula is TRUE | Staged |
| [`row delete hidden`](#row-delete) | Deletes the rows the filters hide | Staged |
| [`addcol {name} [after\|before {col}] value {text}`](#addcol) | New column, the same text in every row | Staged |
| [`addcol {name} [after\|before {col}] formula {expr}`](#addcol) | New column computed by a formula | Staged |
| [`addcol {name} [after\|before {col}] fill`](#addcol) | New column, asks you for each row's value | Staged |
| [`setcol {col} formula {expr}`](#setcol) | Replaces a column's values with a formula's | Staged |
| [`delcol [{col} ...]`](#delcol) | Deletes columns | Staged |
| [`goto {col}`](#goto) | Moves the cursor to a column | Same |
| [`columns [dtype]`](#columns) | Lists every column's number and name (and with `dtype`, its type); `<CR>` copies a name | Same, with the staged columns |
| [`stats [{col}] [{figure} ...] [n]`](#stats) | Shows a column's figures (all, or only `max`, `newest`, `common`, ...); `<CR>` copies one. A range limits it to those rows | Same, with the staged changes |
| [`hide [{col} ...\|clear]`](#hide) | Not available | Hides columns from the view |
| [`view`](#view-apply-discard) | Opens the table view | |
| [`apply [sort]`](#view-apply-discard) | | Writes the staged changes to the file's buffer |
| [`discard`](#view-apply-discard) | | Throws the staged changes away |
| [`align [on\|off]`](#align) | Turns column alignment on or off | |
| [`decimal {.\|,\|auto}`](#decimal-and-thousands) | Sets the decimal separator for this file | Same |
| [`thousands {,\|.\|space\|'\|none\|auto}`](#decimal-and-thousands) | Sets the thousands separator for this file | Same |
| [`restore [buffer\|file]`](#restore) | Brings back the file as it was when opened | |
| [`preview [stop]`](#preview) | Opens the file in the browser, or stops that | Same |

## sort

<details>
<summary>Examples and details</summary>

```vim
:Csvkit sort price           " by price, smallest first
:Csvkit sort price desc      " largest first
:Csvkit sort                 " by the column under the cursor
:Csvkit sort name str        " compare as text, even if the values look like numbers
:Csvkit sort 3 desc num      " column number 3, compared as numbers
```

- **Type.** csvkit compares numbers as numbers (`9` before `10`), dates as dates and everything else as text. It decides from the column's cells (see [Value types](configuration.md#value-types)). Add `num`, `str` or `date` to force a type; with a forced type, cells that don't fit it go after the ones that do.
- **Empty cells always go last**, whether ascending or descending.
- **Ties keep their order**: rows with equal values stay in the order they had.
- **Text** is compared ignoring case first (`apple` before `Banana`), then with case to break ties. Accented letters are compared by their bytes, so `é` sorts after `z`.
- The header row stays on top. Rows are moved as they are, so quoting and cells spanning several lines are kept exactly.

In the table view, `sort` only reorders the view. `:Csvkit apply sort` writes that order to the file.

</details>

## filter

<details>
<summary>Examples and details</summary>

Filters **hide** rows; they never delete anything. `:w` still saves every row.

**By value.** `:Csvkit filter city` (or `:Csvkit filter` on that column) opens a list of the column's values with how many rows have each, most frequent first:

```
[x] Madrid (120)
[x] Paris (87)
[ ] (empty) (3)
```

| Key | Action |
|---|---|
| `<Space>` or `<Tab>` | Tick or untick the value under the cursor |
| `a` | Tick all, or untick all if all are ticked |
| `<CR>` | Apply: only rows with a ticked value stay visible |
| `q` or `<Esc>` | Close without changing anything |
| `/` | Search the list |

**By condition.** Anything that is not a single column name is a [formula](formulas.md); the rows where it is TRUE stay visible:

```vim
:Csvkit filter price > 100
:Csvkit filter AND(price >= 10, price <= 20)        " between 10 and 20
:Csvkit filter OR(city = "Madrid", city = "Paris")
:Csvkit filter day >= DATE(2024, 1, 1)
:Csvkit filter [unit price] * qty > 1000            " a name with spaces goes in [ ]
```

- A row where the formula can't be computed (an empty or text cell in `price > 100`) is hidden.
- There is one condition at a time: a new one replaces the previous one.
- If the formula has a mistake, or gives no TRUE/FALSE on any row (`price + 1`), you get an error and the filters stay as they were.

**Combining.** Filters on different columns and the condition all apply together (AND): a row stays visible only if it passes every one. `:Csvkit filter clear` removes them all. The value list of a column counts only the rows the *other* filters leave visible (the column's own filter is ignored, so you can tick values back).

The header row is never hidden. Filters follow your edits: after a sort or an edit, they are applied again. How hidden rows are shown is described in [Views: filtering](views.md#filtering).

</details>

## row add

<details>
<summary>Examples and details</summary>

```vim
:Csvkit row add          " below the cursor's row (same as: row add below)
:Csvkit row add above
```

Inserts an empty row with the right number of fields and moves the cursor to it. In a row that spans several lines, the new row goes after (or before) the whole row. A row can't be added above the header.

</details>

## row delete

<details>
<summary>Examples and details</summary>

```vim
:Csvkit row delete                   " the row under the cursor
:'<,'>Csvkit row delete              " every row the selected lines touch (visual mode, then :)
:Csvkit row delete where qty = 0     " every row where the formula is TRUE
:Csvkit row delete hidden            " every row your filters hide
```

- One undo step, however many rows go. The other rows keep their exact text.
- A row that spans several lines is deleted whole.
- The header row is never deleted.
- `where` deletes only rows where the formula is TRUE. A row where it can't be computed (`qty > 0` on an empty cell) is kept, and so is a row your filters hide: the formula only looks at the visible rows.
- `hidden` is the only way filters lead to deleting rows. It needs at least one filter.

</details>

## addcol

<details>
<summary>Examples and details</summary>

Adds a new column whose header is `{name}`: **right after the column under the cursor**, or where you say with `after {col}` or `before {col}`.

```vim
:Csvkit addcol status value pending                  " every row gets "pending"
:Csvkit addcol total formula price * qty * 1.19      " computed for each row
:Csvkit addcol notes fill                            " you type each row's value
:Csvkit addcol id before 0 value 1                   " as the first column
:Csvkit addcol total after -1 formula price * qty    " as the last column
:Csvkit addcol tax after price formula price * 0.19  " right after price
:Csvkit addcol                                       " asks for the name, the position, the kind and the text
```

- **Position**: `after {col}` or `before {col}` goes between the name and the kind, with `{col}` written as anywhere else (a name, a number, `-1` for the last). Leave it out to use the column under the cursor. When `:Csvkit addcol` asks for the position, type `before 0`, `after price`, ..., or press Enter for the column under the cursor.
- **`value {text}`**: every row gets the same text (spaces included).
- **`formula {expr}`**: the [formula](formulas.md) is computed once for every visible row, and the **results** are written into the file as plain values. Nothing is recalculated later. A row your filters hide gets an empty cell. A visible row where the formula fails gets an empty cell too, and a warning names those rows by line number:

  ```
  csvkit: 2 cells failed (rows 4, 9): division by zero
  ```

- **`fill`**: csvkit highlights each row in turn and asks for its value, showing that row's other values in the prompt (`Row 12 [name=Ana, age=30] >`). Press `<CR>` with nothing typed to leave a cell empty. `<Esc>` stops early: the rows not reached stay empty, and what you typed is kept.

The whole column is added in one edit, so one `u` removes it. Values are quoted only when needed (or always, if every field in the file is quoted).

</details>

## setcol

<details>
<summary>Examples and details</summary>

```vim
:Csvkit setcol price formula price * 1.19                      " raise every price by 19%
:Csvkit setcol growth formula (Total - PREV(Total)) / PREV(Total)
:Csvkit setcol -1 formula IF($-1 = "", 0, $-1)                 " fill the blanks of the last column with 0
```

Like `addcol ... formula`, but the results replace the cells of an **existing** column. The formula may read the column it replaces (`price * 1.19`).

- Only that column's text changes; the other fields of each row keep their exact text.
- With filters on, only the visible rows change; the hidden ones keep their values.
- A row where the formula fails gets an **empty** cell, and a warning names those rows. `u` brings the old values back.
- [`PREV`](formulas.md#prev-the-row-before) reads the rows in the order you see them when you run the command.

</details>

## delcol

<details>
<summary>Examples and details</summary>

```vim
:Csvkit delcol                       " the column under the cursor
:Csvkit delcol 3                     " column number 3 (the 4th)
:Csvkit delcol 2-5 notes 8           " several at once: a range, a name, a number
:Csvkit delcol 2--1                  " from column 2 to the last
```

Deletes the columns from every row, header included, in one undo step. The other fields keep their exact text. You can't delete every column. If a column's name looks like a range (a column called `1-2`), the name wins.

</details>

## goto

<details>
<summary>Examples and details</summary>

```vim
:Csvkit goto price
:Csvkit goto 12
:Csvkit goto -1                      " the last column
```

Moves the cursor to that column on the current row, and scrolls the window sideways so the column starts at its left edge. Useful in wide files.

</details>

## columns

<details>
<summary>Examples and details</summary>

```vim
:Csvkit columns [dtype]
```

Opens a window listing every column: its number (from 0, as `{col}` takes it) and its name.

```
0   date
1   unit price
2   a very long name wraps here and goes on
    under the name, not under the number
...
11  notes
```

- **Long names wrap**, and their next lines start under the name, so the numbers stay readable.
- **Many columns**: the window is never taller than the screen; scroll it, or search it with `/`. The title says how many columns there are.
- A cell spanning several lines in the header shows `⏎` where it breaks. A column with no name, or a file without a header row (`header = false`), shows the number only.
- In the table view, columns added or deleted there (staged) count.
- **`dtype`** adds each column's type after its name: `number`, `date`, `bool` or `string` (see [Value types](configuration.md#value-types)). It reads every row (in the table view, the rows shown), so on a big file it takes a moment and briefly holds the file's cells in memory.

| Key | Action |
|---|---|
| `<CR>` | Copy the name on the cursor's line (the number, for a column with no name) and close |
| `q` or `<Esc>` | Close |

</details>

## stats

<details>
<summary>Examples and details</summary>

```vim
:Csvkit stats                 " every figure of the column under the cursor
:Csvkit stats price           " every figure of a column, by name or number
:Csvkit stats price max       " only the largest value
:Csvkit stats price max sum   " only those two
:Csvkit stats day newest      " the most recent date
:Csvkit stats city common     " the most frequent value
:Csvkit stats city values     " every value with how many rows have it
:Csvkit stats price largest 10   " the 10 largest values (n is 5 when left out)
:Csvkit stats price 10        " every figure, with 10 largest and smallest
:'<,'>Csvkit stats price      " only the rows you selected (visual mode, then :)
:10,20Csvkit stats price      " only the rows on lines 10 to 20
```

Opens a window with the column's figures. Nothing is copied until you choose a line:

```
type         number
rows         9
empty        1
unique       5
most common  12 (3 times)
min          -4
max          30
sum          117.5
average      14.6875

largest 3
  30
  30
  18
smallest 3
  -4
  7.5
  12

values
  count  value
      3  12
      2  30
      1  (empty)
      1  -4
      1  18
      1  7.5
```

| Key | Action |
|---|---|
| `<CR>` | Copy the value on the cursor's line and close. It goes to the system clipboard (when Neovim has one) and to the unnamed register, so `p` pastes it |
| `q` or `<Esc>` | Close |

**Figures** you can ask for, one or several, after the column:

| Figure | What it is | Columns |
|---|---|---|
| `type` | number, date, bool or string | any |
| `rows` | rows counted | any |
| `empty` | empty cells | any |
| `unique` | distinct non-empty values | any |
| `common` | the most frequent value, and how many times | any |
| `min`, `max` | the smallest and largest value (for dates: the oldest and newest) | numbers, dates |
| `oldest`, `newest` | the same as `min` and `max`, for dates | dates |
| `sum`, `average` | | numbers |
| `largest`, `smallest` | the n largest or smallest values (newest or oldest for dates); n is a number after the figures, 5 by default | numbers, dates |
| `values` | every distinct value with how many rows have it, most frequent first | any |

- **A figure the column can't have is an error**, not an empty line: `:Csvkit stats name sum` on a text column says `sum needs a number column, and this one is string`. A column is numbers or dates only when **all** its non-empty cells are (see [Value types](configuration.md#value-types)); one text cell makes it text.
- **The first word is the column** when a column has that name, so a column called `type` or `max` still works: `:Csvkit stats type` is the column `type`, `:Csvkit stats type common` its most frequent value. Leave the column out (`:Csvkit stats max`) only when no column has the figure's name.
- **n** (a number after the column) sets how many values `largest` and `smallest` list. It only goes with them: `:Csvkit stats price max 3` is an error.
- **Only the rows you see count.** Rows your filters hide are left out. In the table view, staged changes count too.
- **A range** (Vim's line range, written before `Csvkit`: `:10,20`, `:'<,'>`, `:.,+9`) keeps only the rows on those lines, still without the hidden ones. In the file's buffer the numbers are the file's line numbers (`:set number` shows them; line 1 is the header), and a row spanning several lines counts if any of its lines is in the range. In the table view they are the view's lines. The window's title shows the range.
- **Values are shown as the file writes them** (`1.234,5` stays as it is). The sum and average use the file's decimal separator.
- The window is a normal read-only buffer: `/` searches it, and you can select and `y` any part of it.

</details>

## hide

<details>
<summary>Examples and details</summary>

Table view only (the browser has its own "hide column").

```vim
:Csvkit hide                         " the column under the cursor
:Csvkit hide 3-7 notes
:Csvkit hide clear                   " show every column again
```

Hiding only affects what you see. `:Csvkit apply` still writes hidden columns to the file.

</details>

## view, apply, discard

<details>
<summary>Examples and details</summary>

```vim
:Csvkit view          " open the table view of this file (in the same window)
:Csvkit apply         " write the staged changes to the file's buffer
:Csvkit apply sort    " the same, and also write the view's sort order
:Csvkit discard       " throw the staged changes and the sort away
```

See [Views: table view](views.md#table-view) for how the table view works.

- `apply` changes the file's **buffer**, as one undo step. Save it with `:w` in that buffer.
- `apply` refuses if nothing is staged, or if the file's buffer was edited after the view read it. In that case, `discard` and start again.
- `discard` keeps the filters; `:Csvkit filter clear` removes them.

</details>

## align

<details>
<summary>Examples and details</summary>

```vim
:Csvkit align         " turn alignment on if it is off, off if it is on
:Csvkit align on
:Csvkit align off
```

Turns the [aligned overlay](views.md#aligned-overlay) on or off for the current buffer. It is on by default when a file opens (option `align.enabled`).

</details>

## decimal and thousands

<details>
<summary>Examples and details</summary>

csvkit detects how numbers are written in each file. When it guesses wrong, set it for that file:

```vim
:Csvkit decimal ,          " 3,5 means three and a half
:Csvkit thousands .        " 1.234.567 is one number
:Csvkit thousands space    " 1 234 567
:Csvkit thousands none     " no thousands separator
:Csvkit decimal auto       " back to automatic detection
```

The choice is **remembered for that file** across Neovim sessions (stored in `stdpath("data")/csvkit/files.json`). The buffer must belong to a file on disk. Formulas always use `.` for decimals, whatever you set here.

</details>

## restore

<details>
<summary>Examples and details</summary>

When a file opens, csvkit keeps a copy of it. `:Csvkit restore` brings that original back, even after edits and `:w`.

```vim
:Csvkit restore            " the default mode (restore.mode, "buffer" unless you changed it)
:Csvkit restore buffer
:Csvkit restore file
```

| Mode | What happens |
|---|---|
| `buffer` | The buffer's text goes back to the original, as one edit. `u` undoes it. The file on disk changes only when you `:w` |
| `file` | The copy is put back over the file on disk and the buffer is reloaded from it. The undo history is lost. You are asked first if this would throw away unsaved changes, the undo history, or changes another program made to the file |

The copy is deleted when you close the buffer (`:bdelete`, `:bwipeout`) or quit Neovim, so restore works within one session. Reloading the file with `:e!` keeps the first copy. Set `restore.backup = false` to never make copies (then there is nothing to restore).

</details>

## preview

<details>
<summary>Examples and details</summary>

```vim
:Csvkit preview            " open this file in the browser
:Csvkit preview stop       " stop serving it
```

See [Views: browser preview](views.md#browser-preview).

</details>

## Undo

<details>
<summary>Show details</summary>

Each csvkit command is **one** undo step: `u` takes back the whole sort, the whole new column, and so on.

Every csvkit edit except `row add` replaces lines (a sort replaces all of them), and Neovim keeps the old text of replaced lines for undo. On a big file that adds up quickly (about 85 MB per sort of 1 million rows), so **only the 3 most recent of these csvkit edits stay undoable**. When a fourth one happens, the oldest one, and any of your own edits before it, can no longer be undone. To get back further, use `:Csvkit restore`.

If you set a lower `'undolevels'`, that limit is respected too.

</details>

## Keymaps

<details>
<summary>Show details</summary>

csvkit defines **no keymaps**. Map the commands you use to keys, for example:

```lua
vim.keymap.set("n", "<leader>ks", "<cmd>Csvkit sort asc<cr>", { desc = "Sort ascending" })
vim.keymap.set("n", "<leader>kf", "<cmd>Csvkit filter<cr>", { desc = "Filter column" })
```

`<cmd>` and `<cr>` run the command without leaving normal mode (`<cr>` is the Enter key). The README has an [example](../README.md#suggested-keymaps) that limits the keys to CSV buffers.

<details>
<summary><b>&lt;Plug&gt; mappings</b></summary>

For those who prefer them, these `<Plug>` names exist (normal mode). Each runs the command next to it.

| Mapping | Runs |
|---|---|
| `<Plug>(csvkit-sort-asc)` | `:Csvkit sort asc` |
| `<Plug>(csvkit-sort-desc)` | `:Csvkit sort desc` |
| `<Plug>(csvkit-filter)` | `:Csvkit filter` |
| `<Plug>(csvkit-filter-clear)` | `:Csvkit filter clear` |
| `<Plug>(csvkit-row-below)` | `:Csvkit row add below` |
| `<Plug>(csvkit-row-above)` | `:Csvkit row add above` |
| `<Plug>(csvkit-row-delete)` | `:Csvkit row delete` |
| `<Plug>(csvkit-addcol)` | `:Csvkit addcol` |
| `<Plug>(csvkit-delcol)` | `:Csvkit delcol` |
| `<Plug>(csvkit-hide)` | `:Csvkit hide` |
| `<Plug>(csvkit-stats)` | `:Csvkit stats` |
| `<Plug>(csvkit-align-toggle)` | `:Csvkit align` |
| `<Plug>(csvkit-view)` | `:Csvkit view` |
| `<Plug>(csvkit-apply)` | `:Csvkit apply` |
| `<Plug>(csvkit-apply-sort)` | `:Csvkit apply sort` |
| `<Plug>(csvkit-discard)` | `:Csvkit discard` |
| `<Plug>(csvkit-preview)` | `:Csvkit preview` |
| `<Plug>(csvkit-restore)` | `:Csvkit restore` |

</details>

</details>
