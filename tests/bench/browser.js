// Times the browser page on .bench/NxC.csv in headless Firefox (WebDriver BiDi):
//   node tests/bench/browser.js 100000x10
// A headless Neovim (the code of the tree this script is in) serves the
// preview; Firefox loads it in a fresh profile. Times are measured in the page
// (performance.now), each until two animation frames have run, so the rows are
// drawn. "firefox rss" is how much the Firefox processes grew while loading.
"use strict";
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const shape = process.argv[2];
if (!shape) throw new Error("usage: browser.js NxC");
const root = path.resolve(__dirname, "../..");
const file = path.join(root, ".bench", shape + ".csv");
if (!fs.existsSync(file)) throw new Error(file + " missing; run tests/bench/gen.lua");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "csvkit-browser-"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function until(fn, ms = 600000) {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(20)) {
    const v = fn();
    if (v) return v;
  }
  throw new Error("timed out");
}

// The total resident memory of the processes whose command line has `mark`, in MB.
function rss(mark) {
  let kb = 0;
  for (const pid of fs.readdirSync("/proc").filter((p) => /^\d+$/.test(p))) {
    try {
      if (!fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").includes(mark)) continue;
      kb += +fs.readFileSync(`/proc/${pid}/status`, "utf8").match(/VmRSS:\s+(\d+)/)[1];
    } catch {}
  }
  return kb / 1024;
}

(async () => {
  const urlFile = path.join(tmp, "url");
  const lua = `require("csvkit").setup({ date_formats = { "%Y-%m-%d", "%d/%m/%Y" }, align = { enabled = false } })
    vim.ui.open = function(u) local f = io.open(${JSON.stringify(urlFile)}, "w"); f:write(u); f:close() end
    require("csvkit.preview").start(0)`;
  const nvim = spawn("nvim", ["--headless", "--clean", "--cmd", "set rtp^=" + root, "-c", "lua " + lua.replace(/\n/g, " "), file], { stdio: "ignore" });
  const url = await until(() => fs.existsSync(urlFile) && fs.readFileSync(urlFile, "utf8"));

  const profile = path.join(tmp, "profile");
  fs.mkdirSync(profile);
  const ff = spawn("firefox", ["--headless", "--no-remote", "--profile", profile, "--remote-debugging-port", "0"], { stdio: ["ignore", "ignore", "pipe"] });
  let log = "";
  ff.stderr.on("data", (d) => (log += d));
  const ws = new WebSocket((await until(() => log.match(/WebDriver BiDi listening on (ws:\/\/\S+)/)))[1] + "/session");
  await new Promise((r) => (ws.onopen = r));
  let id = 0;
  const waiting = new Map();
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (waiting.has(msg.id)) {
      waiting.get(msg.id)(msg);
      waiting.delete(msg.id);
    }
  };
  const send = (method, params) =>
    new Promise((resolve, reject) => {
      const n = ++id;
      waiting.set(n, (msg) => (msg.error ? reject(new Error(msg.error + ": " + msg.message)) : resolve(msg.result)));
      ws.send(JSON.stringify({ id: n, method, params }));
    });
  await send("session.new", { capabilities: {} });
  const context = (await send("browsingContext.create", { type: "tab" })).context;
  await send("browsingContext.setViewport", { context, viewport: { width: 1400, height: 900 } });
  // runs an async function body in the page; returns its value
  const page = async (body) => {
    const r = await send("script.evaluate", {
      expression: `(async () => { const $ = (id) => document.getElementById(id); const frames = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))); ${body} })()`,
      target: { context },
      awaitPromise: true,
    });
    if (r.type === "exception") throw new Error(JSON.stringify(r.exceptionDetails.text));
    return r.result.value;
  };
  const report = (name, ms) => console.log(`${name.padEnd(36)} ${ms.toFixed(0).padStart(8)} ms`);
  const timed = async (name, body) => report(name, await page(`const t = performance.now(); ${body}; await frames(); return performance.now() - t;`));

  const before = rss(profile);
  await send("browsingContext.navigate", { context, url, wait: "complete" });
  const load = JSON.parse(await page(`
    while ($("status").textContent !== "live") await new Promise((r) => setTimeout(r, 5));
    await frames();
    const e = performance.getEntriesByType("resource").find((e) => e.name.includes("/data"));
    return JSON.stringify({ load: performance.now(), server: e.responseStart - e.requestStart, download: e.responseEnd - e.responseStart, size: e.decodedBodySize });`));
  report("load (until the rows are drawn)", load.load);
  report("  of it: Neovim builds /data", load.server);
  report("  of it: download", load.download);
  console.log(`  ${(load.size / 1e6).toFixed(1)} MB of JSON`);
  await sleep(500);
  console.log(`firefox rss +${(rss(profile) - before).toFixed(0)} MB after load`);

  const header = JSON.parse(await page(`return JSON.stringify(data.cols.map((c) => c.name));`));
  const col = (name) => header.indexOf(name);
  const click = (sel) => `document.querySelector(${JSON.stringify(sel)}).click()`;
  await timed("sort price (number)", click(`#hd [data-c="${col("price")}"] span`));
  await timed("sort price desc", click(`#hd [data-c="${col("price")}"] span`));
  await timed("sort off", click(`#hd [data-c="${col("price")}"] span`));
  await timed("sort name (text)", click(`#hd [data-c="${col("name")}"] span`));
  await timed("sort memo (text, unique-ish)", click(`#hd [data-c="${col("memo")}"] span`));
  await timed("filter menu: flag", click(`#hd [data-f="${col("flag")}"]`));
  await timed("filter: uncheck one value", click(`#vals input`));
  await timed("filter menu: id (all distinct)", click(`#hd [data-f="${col("id")}"]`));
  await timed("filter menu: search '12'", `$("q").value = "12"; $("q").dispatchEvent(new Event("input"))`);
  await timed("clear filters", click("#clear"));
  await timed("scroll to the end", `$("sc").scrollTop = $("sc").scrollHeight`);
  await timed("reload (fetch + parse + draw)", `await load()`);
  console.log(`firefox rss +${(rss(profile) - before).toFixed(0)} MB at the end`);

  ws.close();
  ff.kill("SIGKILL");
  nvim.kill("SIGKILL");
  await sleep(300);
  fs.rmSync(tmp, { recursive: true, force: true });
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
