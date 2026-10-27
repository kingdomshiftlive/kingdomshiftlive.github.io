import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { Script } from "node:vm";
import { createHash } from "node:crypto";
const root = new URL("../", import.meta.url), dist = new URL("dist/", root);
const url = process.env.PUBLIC_SUPABASE_URL || "";
const key = process.env.PUBLIC_SUPABASE_ANON_KEY || "";
if (!url || !key) {
  throw Error(
    "Set PUBLIC_SUPABASE_URL and PUBLIC_SUPABASE_ANON_KEY before building. Only public browser configuration belongs here.",
  );
}
const parsed = new URL(url);
if (
  parsed.protocol !== "https:" &&
  !["localhost", "127.0.0.1"].includes(parsed.hostname)
) throw Error("Use HTTPS for the Supabase URL");
if (key.startsWith("eyJ")) {
  let claims;
  try {
    claims = JSON.parse(Buffer.from(key.split(".")[1], "base64url").toString());
  } catch {
    throw Error("Invalid public Supabase key");
  }
  if (claims.role !== "anon") {
    throw Error(
      "Only an anon/publishable Supabase key may be included in the website",
    );
  }
} else if (!key.startsWith("sb_publishable_")) {
  throw Error(
    "Only a Supabase publishable or legacy anon key may be included in the website",
  );
}
if (parsed.username || parsed.password) {
  throw Error("Credentials must not be embedded in the Supabase URL");
}

for (
  const file of ["app/customer.js", "app/services.js", "app/config.js", "sw.js"]
) new Script(await readFile(new URL(file, root), "utf8"), { filename: file });
const html = await readFile(new URL("index.html", root), "utf8");
for (
  const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)
) new Script(match[1]);
await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
const files = [
  "index.html",
  "404.html",
  "privacy.html",
  "child-safety.html",
  "delete-account.html",
  "manifest.json",
  "sw.js",
  "logo.png",
  "icon-192.png",
  "icon-512.png",
  "robots.txt",
  "sitemap.xml",
  "app",
  "vendor",
  ".well-known",
  "ks_live_deploy/index.html",
  "ks_live_deploy/404.html",
  "ks_live_deploy/sw.js",
  "ks_live_deploy/manifest.json",
  "ks_live_deploy/logo.png",
];
for (const file of files) {
  await cp(new URL(file, root), new URL(file, dist), { recursive: true });
}
await writeFile(
  new URL("app/config.js", dist),
  "window.KINGDOMSHIFT_CONFIG=" +
    JSON.stringify({ supabaseURL: url, supabaseAnonKey: key }).replace(
      /</g,
      "\\u003c",
    ) + ";\n",
);
await writeFile(new URL(".nojekyll", dist), "");
await writeFile(
  new URL("build-info.json", dist),
  JSON.stringify({
    commit: process.env.GITHUB_SHA || "local",
    applicationSha256: createHash("sha256").update(html).digest("hex"),
  }) + "\n",
);
console.log(
  "Built static site in dist/; server source, migrations, test data, and credentials are excluded.",
);
