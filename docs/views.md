# Views

csvkit gives you three ways to look at a CSV file:

| View | What it is | Changes the file? | Use it for |
|---|---|---|---|
| [Aligned overlay](#aligned-overlay) | The file itself, with its columns lined up | Yes: you edit the file directly | Everyday reading and editing |
| [Table view](#table-view) | A separate table built from the file | Only when you run `:Csvkit apply` | Trying out sorts, filters and new columns before changing the file |
| [Browser preview](#browser-preview) | A page in your web browser | Never | Browsing a big table with the mouse |

## Aligned overlay

When you open a CSV file, csvkit lines its columns up.

> [!WARNING]
> **Rows with a line break inside a cell are not aligned.** CSV allows a quoted cell to contain line breaks (`"first line` / `second line"`), so one row then takes several lines of the file. Neovim can't draw several lines of a file as one screen line, so such a row is shown as it is, as raw comma-separated text across its lines, and it does not count toward the column widths. The rows around it are still aligned. A file where many cells hold line breaks (long descriptions, for example) will look mostly unaligned. To read such a file, use the [table view](#table-view) (`:Csvkit view`): it shows every row on one line, with each line break as `⏎`. Editing, sorting and every other command handle these rows correctly; only the alignment is missing.

<details>
<summary>Show details</summary>

```
id,name,city            becomes      id │ name  │ city
1,Ana,Madrid                         1  │ Ana   │ Madrid
22,Luis,Paris                        22 │ Luis  │ Paris
```

The padding and the `│` are only **drawn on screen**. The file's text is untouched: the buffer still holds `1,Ana,Madrid`, you edit it normally, and `:w` saves exactly that.

- **Turn it on or off** with `:Csvkit align` (or `align on` / `align off`). To have files open unaligned, set `align.enabled = false`.
- **Column widths** come from the widest cell in each column over the **whole file**, so columns don't shift as you scroll. On a big file the widths are measured in the background; the first screen is aligned right away. After an edit, a column grows at once if needed, and shrinks once the background measurement has finished.
- **Long lines don't wrap** while the overlay is on: each row stays on one screen line, and you scroll sideways (`zl`, `zh`, `zL`, `zH`) to see columns past the window's edge. Your `'wrap'` setting comes back when the overlay is turned off. `:Csvkit goto {col}` jumps straight to a column.
- **Sticky header**: the top bar of the window (the `winbar`) shows the header row, aligned with the columns below it, and follows sideways scrolling. Each name is shown after its column number (`0 id │ 1 name │ 2 city`), the number commands and formulas take. Turn it off with `align.sticky_header = false`. Files without a header row (`header = false`) don't get one.

</details>

## Filtering

<details>
<summary>Show details</summary>

Filters hide the rows you don't want to see (see [`:Csvkit filter`](commands.md#filter) for how to set them). In the file's buffer, hidden rows are collapsed into **folds** (Neovim's own, no plugin needed): each run of hidden rows becomes one line that says how many rows it hides:

```
id │ name  │ city
1  │ Ana   │ Madrid
⋯ 2 hidden rows
4  │ Eva   │ Madrid
```

- Filters only **hide**. The rows are still in the file, and `:w` saves all of them. To delete the hidden rows for real, use `:Csvkit row delete hidden`.
- Filters on several columns, and a filter condition, all apply together: a row stays visible only if it passes every one.
- The header row is never hidden.
- Filters follow your edits: after a sort, an insert or an undo, the right rows are hidden again.
- **While a filter is on, csvkit controls the window's folds.** Your fold settings are saved and put back by `:Csvkit filter clear`, but any manual folds you had made in that window (`zf`) are removed.

</details>

## Table view

<details>
<summary>Show details</summary>

`:Csvkit view` replaces the file in the current window with a table built from it:

```
 2 of 5 rows │ filter city: Madrid │ sort total ↓ │ staged: 1 new column (:Csvkit apply | discard)
┌──────┬────────┬──────────┬─────────┐
│ 0 id │ 1 name │ 2 city   │ 3 total │
├──────┼────────┼──────────┼─────────┤
│ 4    │ Eva    │ Madrid   │ 120     │
│ 1    │ Ana    │ Madrid   │ 80      │
└──────┴────────┴──────────┴─────────┘
```

The first line sums up what is going on: how many rows are shown, the filters, the sort, hidden columns, and the changes waiting to be applied. It lists at most 3 values per filter (`+2` says how many more) and can be wider than the window: press `<CR>` on it to see all of it, every filter value and every hidden column, one item per line.

</details>

### Everything is staged

<details>
<summary>Show details</summary>

In the table view, nothing you do changes the file right away. Changes are **staged**: the table shows the result at once, and they are written to the file only when you run `:Csvkit apply`. That makes the view a safe place to try things.

| To | Do this |
|---|---|
| Sort | `:Csvkit sort {col} [desc]` |
| Filter | `:Csvkit filter {col}` or `:Csvkit filter {expr}` |
| Hide columns | `:Csvkit hide {col} ...`; `:Csvkit hide clear` shows them again |
| Go to a column | `:Csvkit goto {col}` |
| Edit a cell | Put the cursor on it and press `i`. On the header row, `i` renames the column |
| Add a row | `:Csvkit row add [above\|below]` (a new row is never hidden by a filter, so you can fill it in) |
| Delete rows | `:Csvkit row delete` (the cursor's row, or a range), `row delete where {expr}`, `row delete hidden` |
| Add a column | `:Csvkit addcol ...` (its formula may use other staged columns) |
| Replace a column's values | `:Csvkit setcol {col} formula {expr}` |
| Delete columns | `:Csvkit delcol {col} ...` |
| Move a column | `:Csvkit mv col {col} {index}` (`-1` is the end) |
| See the row in the file | `<CR>`: jumps to that row in the file's buffer |
| See all of the first line | `<CR>` on it |
| See a column's figures | `:Csvkit stats {col}`: max, newest date, most common value, ... over the rows shown, staged changes included |
| **Write the changes to the file** | `:Csvkit apply` (also writes the sort order: `:Csvkit apply sort`) |
| **Throw everything away** | `:Csvkit discard`: staged changes, sort, filters and hidden columns |

</details>

### Applying

<details>
<summary>Show details</summary>

- `:Csvkit apply` writes the staged changes into the **file's buffer** as one edit: one `u` there undoes all of it. Then save with `:w` from the file's buffer. (`:w` doesn't work in the table view itself: it is not a file.)
- Rows are written in the file's order. To also write the view's sort order, use `:Csvkit apply sort`.
- **Filters and hidden columns are never applied**: hidden rows and columns are still written. To delete rows or columns, use `row delete` and `delcol`.
- Rows you didn't touch keep their exact text. Edited and new rows are written in the file's quoting style. When a column is deleted in the view, every row is written again in that style.
- `apply` refuses if nothing is staged, or if the file's buffer was edited after the view read it. Run `:Csvkit discard` to throw the staged changes away and read the file again.
- `:Csvkit discard` drops the staged changes, the sort, the filters and the hidden columns.

</details>

### Moving between the view and the file

- `<CR>` (or `:b` and the file's name) goes back to the file. The view is kept, with its staged changes; `:Csvkit view` from the file shows it again.
- `:bdelete` in the view closes it for good, dropping any staged changes; the window shows the file again. (`:q` would close the window instead.)
- When nothing is staged, the view follows your edits to the file: about 150 ms after you stop typing, it shows the new text. While changes are staged it doesn't, because that would lose them; its first line tells you the file changed.

### Big tables

<details>
<summary>Show details</summary>

- Up to 5,000 rows, the whole table is drawn at once.
- Above that, every line exists (so `G` and scrolling work), but rows are filled in as they come close to the window. Because of this, `/` only finds rows that have already been drawn, and column widths are first measured on the first 2,000 rows (a wider cell further down widens its column when it is drawn).
- Each column is as wide as its widest cell. Set [`view.max_col_width`](configuration.md#viewmax_col_width) to a positive number to cut long cells (shown with `…`; the file keeps the full text).
- Staged cells are counted on the first line but not highlighted.

</details>

## Browser preview

<details>
<summary>Show details</summary>

`:Csvkit preview` opens the file in your web browser, in a table with smooth scrolling, sorting and filtering. `:Csvkit preview stop` stops it.

- **Read-only.** Nothing you do in the page changes the file, and sorting or filtering in the page doesn't affect Neovim. All editing happens in Neovim.
- **Live.** When you edit the file in Neovim, the page reloads by itself, keeping its scroll position, sort and filters. It waits until you stop typing for [`preview.debounce_ms`](configuration.md#preview) (300 ms by default) so it reloads once, not on every key. Files over [`preview.live_update_max_mb`](configuration.md#preview) (2 MB by default) reload when you save with `:w` instead, because preparing the page's data pauses Neovim briefly.
- **Sort:** click a column header: ascending, then descending, then back to the file's order. Numbers and dates sort by value, the same way as in Neovim. Text sorts the way your browser orders words, ignoring accents, so for accented text the order can differ slightly from `:Csvkit sort`.
- **Filter:** the `▾` on a header opens the column's values with their counts, with a search box (the list shows at most 500 values; search to find others). The box in the top bar takes a [formula](formulas.md), like `:Csvkit filter {expr}`: Enter applies it, an empty box + Enter removes it. "clear filters" removes all of them.
- **Columns:** "go to column" takes a number or a name. The `▾` menu can hide a column; "show hidden columns" brings them back. Each column is as wide as its widest cell, or at most [`view.max_col_width`](configuration.md#viewmax_col_width) characters when that is not `0` (the same limit as the table view; longer cells end with `…`).
- **Row numbers** on the left are the line numbers in the file.
- Several files can be previewed at once; each gets its own page.

</details>

<details>
<summary><b>Security</b></summary>

- The page is served only on your own machine (`127.0.0.1`), on a random port unless you set [`preview.port`](configuration.md#preview). Other computers can't reach it.
- Its address contains a random secret (`http://127.0.0.1:PORT/SECRET/?buf=N`). Without the secret every request is refused, so other web pages open in your browser can't read your data.
- The page loads nothing from the internet and sends nothing anywhere except to Neovim.
- Csvkit opens the address in your browser, so the secret appears on the browser's command line. On a computer shared with other users, they could see it in the process list and read the previewed file while the preview runs. Use `:Csvkit preview stop` when you are done.

</details>

<details>
<summary><b>Limits</b></summary>

- A 100k-row file takes about 1.2 s to appear; a 1-million-row file about 10 s, during which Neovim is busy.
- Tested in Firefox.
- `:Csvkit preview` run from a table view previews the file the view comes from, not the view: the view's sort, filters, hidden columns and staged edits are not shown.

</details>
