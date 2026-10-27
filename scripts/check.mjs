import { readdir, readFile } from "node:fs/promises";
import { Script } from "node:vm";
for (const dir of ["app", "supabase/functions/_shared", "scripts", "tests"]) {
  for (const file of await readdir(dir)) {
    if (!/\.(?:m?js)$/.test(file)) continue;
    const source = await readFile(dir + "/" + file, "utf8");
    if (file.endsWith(".mjs")) {
      const { spawnSync } = await import("node:child_process");
      const result = spawnSync(
        process.execPath,
        ["--check", dir + "/" + file],
        { stdio: "inherit" },
      );
      if (result.status) process.exit(result.status);
    } else new Script(source, { filename: dir + "/" + file });
  }
}
for (const file of ["index.html", "404.html", "ks_live_deploy/index.html"]) {
  for (
    const match of (await readFile(file, "utf8")).matchAll(
      /<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g,
    )
  ) new Script(match[1], { filename: file });
}
console.log(
  "Application, backend modules, scripts, tests, and inline JavaScript parse successfully.",
);
