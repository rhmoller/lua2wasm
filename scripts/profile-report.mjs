// Reports for scripts/profile.sh (see docs/perf-backlog.md, "Measuring").
//
//   node scripts/profile-report.mjs top FILE.cpuprofile [N] [--tree]
//       the N functions with the most self time; --tree adds the call tree
//       (inclusive time, branches under 1% pruned)
//   node scripts/profile-report.mjs inlining FUNCTION_MAP TRACE NAME
//       V8's inlining decisions while optimizing function NAME, with function
//       indices replaced by names. FUNCTION_MAP is `wasm-opt --print-function-map`
//       output, TRACE is `node --trace-wasm-inlining` output.
import { readFileSync } from "node:fs";

const [mode, ...args] = process.argv.slice(2);

if (mode === "top") {
    const prof = JSON.parse(readFileSync(args[0], "utf8"));
    const n = Number(args[1]) || 25;
    const byId = new Map(prof.nodes.map(node => [node.id, node]));
    const selfById = new Map();
    let total = 0;
    prof.samples.forEach((id, i) => {
        selfById.set(id, (selfById.get(id) || 0) + prof.timeDeltas[i]);
        total += prof.timeDeltas[i];
    });
    const name = node => node.callFrame.functionName || `(anonymous ${node.callFrame.url.split("/").pop()})`;
    const selfByName = new Map();
    for (const [id, t] of selfById) {
        const k = name(byId.get(id));
        selfByName.set(k, (selfByName.get(k) || 0) + t);
    }
    const pct = t => ((100 * t) / total).toFixed(1).padStart(5) + "%";
    for (const [k, t] of [...selfByName].sort((a, b) => b[1] - a[1]).slice(0, n)) console.log(`${pct(t)}  ${k}`);
    if (args.includes("--tree")) {
        console.log("\ncall tree (inclusive, self):");
        const incl = node => (node.incl ??= (selfById.get(node.id) || 0) +
            (node.children || []).reduce((s, c) => s + incl(byId.get(c)), 0));
        const walk = (node, depth) => {
            if ((100 * incl(node)) / total < 1) return;
            console.log(`${"  ".repeat(depth)}${pct(incl(node))} (${pct(selfById.get(node.id) || 0).trim()}) ${name(node)}`);
            for (const c of (node.children || []).map(c => byId.get(c)).sort((a, b) => incl(b) - incl(a))) walk(c, depth + 1);
        };
        walk(prof.nodes[0], 0);
    }
} else if (mode === "inlining") {
    const names = new Map();
    for (const line of readFileSync(args[0], "utf8").split("\n")) {
        const m = line.match(/^(\d+):(.*)$/);
        if (m) names.set(m[1], m[2]);
    }
    const target = [...names].find(([, nm]) => nm === args[2]);
    if (!target) {
        console.error(`no function named ${args[2]}`);
        process.exit(1);
    }
    const named = s => s.replace(/function (\d+)/g, (_, i) => `${names.get(i) ?? "?"}#${i}`);
    for (const line of readFileSync(args[1], "utf8").split("\n"))
        if (line.startsWith(`[function ${target[0]}:`)) console.log(named(line));
} else {
    console.error("usage: profile-report.mjs top FILE.cpuprofile [N] [--tree] | inlining FUNCTION_MAP TRACE NAME");
    process.exit(2);
}
