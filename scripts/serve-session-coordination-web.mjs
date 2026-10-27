import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

// Synthetic SDK experiment only. This never serves the Nene app, repository,
// Auth credentials or a proxy; only these two fixed compiled fixture assets.
const assets = new Map([
  ["/", ["index.html", "text/html; charset=utf-8"]],
  ["/index.html", ["index.html", "text/html; charset=utf-8"]],
  ["/probe.js", ["probe.js", "application/javascript; charset=utf-8"]],
]);
const root = new URL("../.tmp/session-coordination-web/", import.meta.url);
const content = new Map();
for (const [name] of assets.values()) {
  if (!content.has(name))
    content.set(name, await readFile(new URL(name, root)));
}

const server = createServer((request, response) => {
  if (request.method !== "GET") {
    response.writeHead(405).end();
    return;
  }
  const pathname = new URL(request.url, "http://127.0.0.1").pathname;
  const asset = assets.get(pathname);
  if (!asset) {
    response.writeHead(404).end();
    return;
  }
  response.writeHead(200, {
    "Content-Type": asset[1],
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  response.end(content.get(asset[0]));
});

let port;
for (let candidate = 4179; candidate <= 4199; candidate++) {
  try {
    await new Promise((resolve, reject) => {
      const failed = (error) => {
        server.off("listening", started);
        reject(error);
      };
      const started = () => {
        server.off("error", failed);
        resolve();
      };
      server.once("error", failed);
      server.once("listening", started);
      server.listen(candidate, "127.0.0.1");
    });
    port = candidate;
    break;
  } catch (error) {
    if (!["EADDRINUSE", "EACCES"].includes(error.code)) throw error;
  }
}
if (!port) throw new Error("No free isolated preview port in 4179–4199.");
console.log(
  `Synthetic session-coordination fixture: http://127.0.0.1:${port}/`,
);
console.log(`Assets: ${fileURLToPath(root)}. Auto-stops after 15 minutes.`);
const shutdown = () => {
  clearTimeout(deadline);
  server.closeAllConnections();
  server.close();
  process.stdin.pause();
};
const deadline = setTimeout(shutdown, 15 * 60 * 1000);
process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
process.stdin.setEncoding("utf8");
process.stdin.on("data", (value) => {
  if (value.trim().toLowerCase() === "q") shutdown();
});
