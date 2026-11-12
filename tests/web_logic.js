// Run by tests/test_web.lua: node tests/web_logic.js <path to the logic script>
const assert = require("assert");
const src = require("fs").readFileSync(process.argv[2], "utf8");
const { order, uniques, chars } = new Function(src + "; return { order, uniques, chars };")();

// the payload is by column: cells[c][r]
const byColumn = (rows) => {
  const n = Math.max(0, ...rows.map((r) => r.length));
  return Array.from({ length: n }, (_, c) => rows.map((r) => r[c]));
};
const rows = [["bob", "10", "Paris"], ["Ana", "9", "Madrid"], ["", "", "Paris"], ["cy", "30", ""], ["ana", "9", "Paris"]];
const data = {
  cols: [{ name: "name", type: "string" }, { name: "age", type: "number" }, { name: "city", type: "string" }],
  n: rows.length,
  cells: byColumn(rows),
  keys: { "2": [10, 9, null, 30, 9] },
};
const o = (state) => Array.from(order(data, state));
const none = { filters: new Map(), sort: null };

assert.deepStrictEqual(o(none), [0, 1, 2, 3, 4], "no sort, no filter");
// numbers use keys, not text ('10' > '9'); ties keep the original order; empties last
assert.deepStrictEqual(o({ filters: new Map(), sort: { col: 1, desc: false } }), [1, 4, 0, 3, 2]);
assert.deepStrictEqual(o({ filters: new Map(), sort: { col: 1, desc: true } }), [3, 0, 1, 4, 2], "desc: empties still last");
// strings: case-insensitive, stable, empties last
assert.deepStrictEqual(o({ filters: new Map(), sort: { col: 0, desc: false } }), [1, 4, 0, 3, 2]);
assert.deepStrictEqual(o({ filters: new Map(), sort: { col: 0, desc: true } }), [3, 0, 1, 4, 2]);
// filters: AND across columns, values compared trimmed, "" is the blank cells
assert.deepStrictEqual(o({ filters: new Map([[2, new Set(["Paris"])]]), sort: null }), [0, 2, 4]);
assert.deepStrictEqual(o({ filters: new Map([[2, new Set(["Paris"])], [1, new Set(["9", ""])]]), sort: null }), [2, 4]);
assert.deepStrictEqual(o({ filters: new Map([[2, new Set([""])]]), sort: null }), [3]);
assert.deepStrictEqual(o({ filters: new Map([[2, new Set()]]), sort: null }), [], "nothing checked hides all");
// filter then sort
assert.deepStrictEqual(o({ filters: new Map([[2, new Set(["Paris"])]]), sort: { col: 1, desc: false } }), [4, 0, 2]);
// uniques: by count, then value; blank as ""
assert.deepStrictEqual(uniques(data, 2), [{ v: "Paris", n: 3 }, { v: "", n: 1 }, { v: "Madrid", n: 1 }]);
// counts over the rows the other filters leave; the column's own filter is ignored
const cityOnly = { filters: new Map([[2, new Set(["Paris"])], [1, new Set(["9"])]]), sort: null };
assert.deepStrictEqual(uniques(data, 2, order(data, cityOnly, 2)), [{ v: "Madrid", n: 1 }, { v: "Paris", n: 1 }]);
assert.deepStrictEqual(uniques(data, 1)[0], { v: "9", n: 2 });
// ragged rows: a missing cell is blank
assert.deepStrictEqual(uniques({ cols: [{}, {}], n: 2, cells: byColumn([["a"], ["a", "b"]]), keys: {} }, 1), [{ v: "", n: 1 }, { v: "b", n: 1 }]);

// text sort by ranks = the old sort of every row with the collator (stable), on random data
const collator = new Intl.Collator(undefined, { sensitivity: "base" });
function reference(rows, col, desc) {
  const v = (r) => (rows[r][col] === undefined ? "" : rows[r][col]);
  const idx = rows.map((_, i) => i);
  const full = idx.filter((i) => v(i).trim() !== ""), empty = idx.filter((i) => v(i).trim() === "");
  full.sort((a, b) => (desc ? -1 : 1) * collator.compare(v(a), v(b)));
  return full.concat(empty);
}
const words = ["ana", "Ana", "ána", "bob", "Bob", "b", "", " ", "zoë", "Zoe", "10", "9", "a b", "ab"];
let seed = 1;
const rand = (n) => ((seed = (seed * 16807) % 2147483647) % n);
for (let round = 0; round < 200; round++) {
  const rs = Array.from({ length: rand(30) }, () => Array.from({ length: 1 + rand(2) }, () => words[rand(words.length)]));
  const d = { cols: [{}, {}], n: rs.length, cells: byColumn(rs), keys: {} };
  for (const desc of [false, true]) {
    assert.deepStrictEqual(Array.from(order(d, { filters: new Map(), sort: { col: 0, desc } })), reference(rs, 0, desc), "round " + round);
  }
}
// number sort by ranks + counting sort = the old comparator sort by key then row; filters; uniques
function refNumbers(keys, idx, desc) {
  const k = Float64Array.from(keys, (v) => (v === null ? NaN : v));
  const full = idx.filter((i) => k[i] === k[i]), empty = idx.filter((i) => k[i] !== k[i]);
  return full.sort((a, b) => (desc ? -1 : 1) * (k[a] - k[b]) || a - b).concat(empty);
}
function refUniques(col, n) {
  const count = new Map();
  for (let i = 0; i < n; i++) count.set((col[i] ?? "").trim(), (count.get((col[i] ?? "").trim()) || 0) + 1);
  return [...count].map(([v, n]) => ({ v, n })).sort((a, b) => b.n - a.n || (a.v < b.v ? -1 : a.v > b.v ? 1 : 0));
}
const nums = [0, -0, 1, 1, 2.5, -3, 1e9, null, null, 7];
for (let round = 0; round < 300; round++) {
  const n = rand(40);
  const keys = Array.from({ length: n }, () => nums[rand(nums.length)]);
  const tag = Array.from({ length: n }, () => words[rand(words.length)]);
  const d = { cols: [{}, {}], n, cells: [keys.map((k) => (k === null ? "" : String(k))), tag], keys: { "1": keys } };
  const allowed = new Set(words.filter(() => rand(2)).map((w) => w.trim()));
  const pass = [...Array(n).keys()].filter((i) => allowed.has(tag[i].trim()));
  for (const desc of [false, true]) {
    assert.deepStrictEqual(Array.from(order(d, { filters: new Map(), sort: { col: 0, desc } })), refNumbers(keys, [...Array(n).keys()], desc), "numbers " + round);
    assert.deepStrictEqual(Array.from(order(d, { filters: new Map([[1, allowed]]), sort: { col: 0, desc } })), refNumbers(keys, pass, desc), "filtered " + round);
  }
  assert.deepStrictEqual(uniques(d, 1), refUniques(tag, n), "uniques " + round);
}
// many distinct numbers take the comparator path: the same order
{
  const n = 3000;
  const keys = Array.from({ length: n }, (_, i) => (i % 50 === 0 ? null : i % 7 === 0 ? 5 : (i * 7919) % 10007 / 3));
  const d = { cols: [{}], n, cells: [keys.map((k) => (k === null ? "" : String(k)))], keys: { "1": keys } };
  for (const desc of [false, true]) {
    assert.deepStrictEqual(Array.from(order(d, { filters: new Map(), sort: { col: 0, desc } })), refNumbers(keys, [...Array(n).keys()], desc), "distinct path");
  }
}
// a filter expression: Neovim sends one "1"/"0" per row; ANDed with the value filters, then sorted
assert.deepStrictEqual(o({ filters: new Map(), sort: null, match: "10011" }), [0, 3, 4]);
assert.deepStrictEqual(o({ filters: new Map([[2, new Set(["Paris"])]]), sort: { col: 1, desc: false }, match: "10011" }), [4, 0]);
// column widths in characters: the widest cell over every row, or the header with its
// index and the sort / filter marks; max_width caps it when set
const wide = { cols: [{ name: "id" }, { name: "note" }], n: 3, cells: byColumn([["1", "a"], ["22", "x".repeat(150)], ["3", ""]]), keys: {} };
assert.deepStrictEqual([chars(wide, 0), chars(wide, 1)], [7, 150]); // "0 id" + 3
assert.deepStrictEqual(chars({ ...wide, max_width: 40 }, 1), 40);
console.log("ok");
