// Loads the built page in jsdom and checks that its script runs and the
// interactive parts render. Optional: needs `npm install` in this folder.
//
//   node docs/reference/smoke.cjs [path/to/dw-reference.html]
const { JSDOM, VirtualConsole } = require("jsdom");
const fs = require("fs");
const path = require("path");

const file = process.argv[2] ?? path.join(__dirname, "dw-reference.html");
const errors = [];
const vc = new VirtualConsole();
vc.on("jsdomError", (e) => errors.push(e.message));
const dom = new JSDOM("<!doctype html><html><head></head><body>" + fs.readFileSync(file, "utf8") + "</body></html>", {
  runScripts: "dangerously",
  virtualConsole: vc,
  beforeParse(w) {
    w.IntersectionObserver = class { observe() {} };
    w.Element.prototype.scrollIntoView = () => {};
  },
});
const d = dom.window.document;
const fail = [];
const check = (what, ok) => { if (!ok) fail.push(what); };

check("no script errors: " + errors.join("; "), errors.length === 0);
check("code figures rendered", d.querySelectorAll("figure.code").length > 50);
check("table of contents built", d.querySelectorAll("#toc a").length > 40);
check("RNG lab rows", d.querySelectorAll("#lab-table tbody tr").length === 16);
check("bestiary rows", d.querySelectorAll("#mon-table tbody tr").length === 40);
check("hero table rows", d.querySelectorAll("#n-table tbody tr").length === 30);
check("Erdrick's sum is 43", d.getElementById("n-out").textContent.includes("Sum43"));

const visible = (q) => {
  const box = d.getElementById("q");
  box.value = q;
  box.dispatchEvent(new dom.window.Event("input"));
  return [...d.querySelectorAll(".entry")].filter((e) => !e.hidden).map((e) => e.id);
};
check("search $E66E finds dodge", visible("$e66e").join() === "dodge");
check("search rainbow finds items", visible("rainbow").includes("items"));
check("search crc finds saves", visible("crc").includes("saves"));

if (fail.length) {
  console.error("smoke test failed:\n  " + fail.join("\n  "));
  process.exit(1);
}
console.log("smoke test ok");
