import assert from "node:assert/strict";
import test, { before, after } from "node:test";
import { fileURLToPath } from "node:url";
import { readdir } from "node:fs/promises";
import { join } from "node:path";

let runtime;
before(async () => {
  process.env.MINIFLARE_REGISTRY_PATH = ".wrangler/registry";
  const { Miniflare, convertV4MiniflareOptions } = await import("miniflare");
  const root = fileURLToPath(new URL("../dist/server", import.meta.url));
  const paths = (await readdir(root, { recursive: true })).filter((path) => /\.(m?js)$/.test(path) && path !== "index.js");
  runtime = new Miniflare(convertV4MiniflareOptions({
    modulesRoot: root,
    modules: ["index.js", ...paths].map((path) => ({ type: "ESModule", path: join(root, path) })),
    compatibilityDate: "2026-10-08",
    compatibilityFlags: ["nodejs_compat"],
    assets: {
      directory: fileURLToPath(new URL("../dist/client", import.meta.url)), binding: "ASSETS",
      run_worker_first: true, routerConfig: { has_user_worker: true },
    },
  }));
});
after(async () => { await runtime?.dispose(); });

async function render(path = "/") {
  return runtime.dispatchFetch(`http://localhost${path}`, { headers: { accept: "text/html" } });
}

test("server-renders the production home page", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /The Agora LA/);
  assert.match(html, /Turn every podcast into a practice field/);
  assert.match(html, /Bring the AI you already use/);
  assert.doesNotMatch(html, /No Agora bill/i);
  assert.match(html, /href="\/favicon-32\.png"/);
  assert.match(html, /href="\/apple-touch-icon\.png"/);
  assert.match(html, /href="\/privacy"/);
  assert.match(html, /href="\/terms"/);
  assert.match(html, /href="\/support"/);
  assert.doesNotMatch(html, /codex-preview|starter project|taking shape/i);
});

for (const [path, heading, requiredText] of [
  ["/privacy", "Privacy Policy", "support@theagorala.com"],
  ["/terms", "Terms of Use", "AI-provider accounts and costs"],
  ["/support", "Listener Support", "Connect AI"],
]) {
  test(`server-renders ${path}`, async () => {
    const response = await render(path);
    assert.equal(response.status, 200);
    const html = await response.text();
    assert.match(html, new RegExp(heading, "i"));
    assert.match(html, new RegExp(requiredText, "i"));
  });
}

test("renders the secure provider return page without storing credentials", async () => {
  const response = await render("/auth/openrouter?code=review-code");
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /Secure AI setup/);
  assert.match(html, /Return to The Agora/);
  assert.match(html, /No credential is stored on this webpage/);
});
