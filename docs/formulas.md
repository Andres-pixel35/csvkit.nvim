# Formulas

Formulas compute a value for every row from the row's other values, much like spreadsheet formulas:

```vim
:Csvkit addcol total formula price * qty * 1.19      " a new column
:Csvkit setcol price formula ROUND(price * 1.1, 2)    " replace an existing column's values
:Csvkit filter total > 100                            " show only the rows where it is TRUE
:Csvkit row delete where qty = 0                      " delete the rows where it is TRUE
```

**A formula runs once.** `addcol` and `setcol` compute it for every row and write the **results** into the file as plain text. Nothing is remembered or recalculated later: if you then change a `price`, its `total` stays as it was. Run the command again to recompute.

**A formula sees only the visible rows.** With filters on, `addcol`, `setcol` and `row delete where` compute it only on the rows you can see: a hidden row keeps its cell (`setcol`), gets an empty one (`addcol`), is never deleted (`row delete where`), and never shows up in the failure warning. [Whole-column functions](#whole-column-functions) and [`PREV`](#prev-the-row-before) read only the visible rows too. A filter's own formula (`filter`, the browser's filter box) reads every row, since it is what decides which rows are visible.

**Types are strict.** csvkit never guesses what you meant: adding a number to a piece of text is an error, not `"5" + 1 = 6`. A row where the formula fails gets an empty cell, and you are told which rows (see [Errors](#errors)).

## Referring to columns

<details>
<summary>Show details</summary>

| You write | It means |
|---|---|
| `price` | The column whose header is `price`. Works for names made of letters, digits and `_` that don't start with a digit |
| `[unit price]` | Any header name, in square brackets: spaces, accents and symbols allowed |
| `$3` | Column number 3. **Numbers count from 0**, so `$3` is the 4th column. Works in files with no header |
| `$-1` | Counting from the end: `$-1` is the last column, `$-2` the one before it |

- Names must match the header exactly, including case: `Price` is not `price`. Spaces at the ends of the header are ignored.
- If two columns have the same name, the name is refused as ambiguous; use `$N` for them.
- A name containing `]` can't go in brackets; use `$N`.

</details>

## Values

<details>
<summary>Show details</summary>

Each cell is read as one of these types (the rules are in [Value types](configuration.md#value-types)):

| Type | In a cell | In a formula |
|---|---|---|
| number | `42`, `3.5` (or `3,5` with `decimal = ","`) | `42`, `3.5` (always with `.`) |
| text | `Madrid` | `"Madrid"`. For a `"` inside, double it: `"say ""hi"""` |
| date | `2024-03-31` (one of `date_formats`) | `DATE(2024, 3, 31)` |
| bool | `true`, `FALSE` | `TRUE`, `FALSE` (any case) |
| empty | nothing, or only spaces | `""` |

Commas separate function arguments, which is why numbers in formulas always use `.` for decimals, even when the file uses `,`.

</details>

## Operators

<details>
<summary>Show details</summary>

| Operator | Meaning | Example |
|---|---|---|
| `+` `-` `*` `/` | Add, subtract, multiply, divide | `price * qty` |
| `%` | Remainder of a division. The result has the sign of the right side: `7 % 3` is `1`, `-7 % 3` is `2` | `id % 2 = 0` (even ids) |
| `^` | Power | `side ^ 2` |
| `-` before a value | Negative | `-price` |
| `=` `<>` | Equal, not equal | `city = "Madrid"` |
| `<` `>` `<=` `>=` | Less than, greater than, ... | `price >= 10` |
| `( )` | Grouping | `(a + b) * c` |

**Order** (which goes first, like in maths): parentheses, then `-` before a value, then `^`, then `*` `/` `%`, then `+` `-`, then the comparisons. So `2 + 3 * 4` is `14`, and `-2^2` is `4`, because the minus belongs to the `2` (as in Excel). `^` groups from the right: `2^3^2` is `2^9`.

</details>

## What can be combined

<details>
<summary>Show details</summary>

| Expression | Result |
|---|---|
| number with number (`+ - * / % ^`) | number. Dividing by 0 is an error |
| text `+` text | the two texts joined: `"ab" + "c"` is `"abc"` |
| text with a number (`"a" + 1`, `"a" * 2`) | error |
| date `+` number, date `-` number | a date that many days later or earlier |
| date `-` date | the number of days between them |
| an empty cell in any arithmetic | error |
| `=` and `<>` between any two values | TRUE or FALSE. Values of different types are never equal: `1 = "1"` is FALSE |
| `<` `>` `<=` `>=` | Both sides must have the same type (two numbers, two texts, two dates); otherwise error |

To test for an empty cell, compare with `""`: `qty = ""`.

</details>

## Functions

Function names can be written in any case (`round` or `ROUND`).

### Whole-column functions

<details>
<summary>Show details</summary>

| Function | Result |
|---|---|
| `SUM(col)` | Sum of the column's numbers |
| `AVG(col)` | Average of the column's numbers |
| `MIN(col)`, `MAX(col)` | Smallest or largest value: numbers, or dates |
| `COUNT(col)` | How many cells are not empty |

They read the column's **visible** rows (every row when no filter is on; every row inside a filter's own formula) and skip empty cells. A cell with text in a `SUM`, `AVG`, `MIN` or `MAX` column makes the function fail, and with it every row. Their argument must be a column, not a calculation: `SUM(price)`, not `SUM(price * 2)`.

```
price / AVG(price)            each price relative to the average
qty / SUM(qty)                each row's share of the total
```

</details>

### Row functions

<details>
<summary>Show details</summary>

| Function | Result | Example |
|---|---|---|
| `MIN(a, b, ...)`, `MAX(a, b, ...)` | Smallest or largest of two or more values in the row | `MAX(q1, q2, q3)` |
| `ABS(x)` | `x` without its sign | `ABS(change)` |
| `ROUND(x, n)` | `x` rounded to `n` decimals; halves round away from zero (`2.5` to `3`, `-2.5` to `-3`). A negative `n` rounds to tens, hundreds... (`ROUND(1234, -2)` is `1200`) | `ROUND(price * 1.19, 2)` |
| `IF(cond, a, b)` | `a` if `cond` is TRUE, `b` if FALSE. `cond` must be TRUE or FALSE, so use a comparison | `IF(qty > 10, price * 0.9, price)` |
| `AND(a, b, ...)`, `OR(a, b, ...)`, `NOT(a)` | Combine TRUE/FALSE values | `AND(age >= 18, age < 30)` |
| `CONCAT(a, b, ...)` | Everything joined as text; numbers and dates are written as they would be in the file, empty cells add nothing | `CONCAT(last, ", ", first)` |
| `UPPER(s)`, `LOWER(s)` | Text in capitals or small letters (accented letters too) | `UPPER(code)` |
| `LEN(s)` | Number of characters (`"José"` is 4) | `LEN(name) > 20` |
| `DATE(y, m, d)` | The date from a year, month and day. An impossible date (`DATE(2023, 2, 30)`) is an error | `DATE(2024, 1, 1)` |
| `TODAY()` | Today's date | `TODAY() - birth` |
| `YEAR(d)`, `MONTH(d)`, `DAY(d)` | The year, month or day of a date, as a number | `YEAR(day) = 2024` |
| `PREV(x)`, `PREV(x, n)` | `x` on the row before (or `n` rows before); 0 when that is empty or missing. See [below](#prev-the-row-before) | `total - PREV(total)` |

`MIN` and `MAX` do both jobs: with **one column** they look at the whole column, with **two or more values** they compare within the row.

</details>

## PREV: the row before

<details>
<summary>Show details</summary>

`PREV(x)` is the value of `x` on the previous row; `PREV(x, 2)` two rows up, and so on. `x` can be any formula: `PREV(price * qty)`.

```vim
:Csvkit addcol change formula total - PREV(total)
:Csvkit setcol growth formula ROUND((total - PREV(total)) / PREV(total), 3)
```

- **"Previous" means as you see the rows when you run the command.** In the file's buffer, that is the file's order, skipping rows your filters hide. In the [table view](views.md#table-view), it is the view's sort order, skipping hidden rows. So sort and filter first, then run the command. The values are written once; sorting again later doesn't change them.
- **Hidden rows are left alone**: they are not computed, and `PREV` skips them.
- **An empty value counts as 0.** When the row `PREV` reads has an empty cell, or there is no such row (the first row, or `PREV(x, 3)` on the first three rows), `PREV` gives **0**, so `total - PREV(total)` works on the first row without any `IF`. Only the row `PREV` reads is checked: `PREV(x, 3)` is 0 when the third row up is empty, whatever the rows in between hold. Change the 0 with the option [`formula.prev_default`](configuration.md#formulaprev_default), for example to `""` to get an empty value (then arithmetic with it fails and the cell is left empty).
- `PREV` works only in `addcol` and `setcol`, not in filters (`filter`, `row delete where`, the browser's filter box). A filter decides which rows are visible, so "the previous visible row" would depend on itself. Compute the column first, then filter on it.

</details>

## Examples

<details>
<summary>Show details</summary>

```
price * qty * 1.19                       price with 19 % tax
IF(qty > 10, price * 0.9, price)         10 % off for more than 10 units
CONCAT(UPPER(last), ", ", first)         "SMITH, Ana"
due - sent                               days between two dates
sent + 30                                the date 30 days later
price / AVG(price)                       relative to the column's average
ROUND(price * qty, 2)                    rounded to cents
IF(qty = "", 0, qty)                     fill empty cells with 0 (with setcol)
AND(age >= 18, age < 30)                 a filter: ages 18 to 29
YEAR(day) = 2024                         a filter: rows from 2024
```

</details>

## Errors

<details>
<summary>Show details</summary>

**A mistake in the formula itself** (a misspelt column or function, a missing parenthesis) is reported before anything is changed, with the position of the problem:

```
csvkit: unknown column "pric" at position 1
csvkit: unexpected end of expression at position 8
```

**A row where the formula can't be computed** (dividing by zero, an empty cell in arithmetic, text mixed with numbers) gets an **empty** cell, and all the other rows are still computed. Afterwards a warning gives the number of failed cells, the line numbers of the first five, and the reason for the first one:

```
csvkit: 7 cells failed (rows 4, 9, 12, 15, 20, …): division by zero
```

In filters, a row where the formula fails is simply hidden (`filter`) or kept (`row delete where`).

</details>

## How results are written

<details>
<summary>Show details</summary>

- Whole numbers are written without decimals: `12`, not `12.0`.
- Other numbers keep up to 15 significant digits, which hides floating-point noise: `0.1 + 0.2` is written as `0.3`, and `1/3` as `0.333333333333333`. They use the file's decimal separator (`0,3` with `decimal = ","`), with no thousands separator.
- Dates are written in the format of the first date in the formula: if `day` is `31/12/2024`, `day + 1` is written `01/01/2025`. `DATE()` and `TODAY()` use the first entry of [`date_formats`](configuration.md#date_formats).
- TRUE/FALSE values are written as `TRUE` and `FALSE`.

</details>
