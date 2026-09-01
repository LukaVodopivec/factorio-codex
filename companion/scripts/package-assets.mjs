import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const packageDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const assetsDir = path.join(packageDir, "assets");
const source = path.resolve(packageDir, "../mod/agentic-companion");
const target = path.join(assetsDir, "agentic-companion");

function clean() {
  fs.rmSync(target, { recursive: true, force: true });
  try {
    if (fs.readdirSync(assetsDir).length === 0) fs.rmdirSync(assetsDir);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

const action = process.argv[2];
if (action === "clean") {
  clean();
} else if (action === "stage") {
  if (!fs.statSync(path.join(source, "info.json")).isFile()) {
    throw new Error(`missing retained mod source: ${source}`);
  }
  clean();
  fs.mkdirSync(assetsDir, { recursive: true });
  fs.cpSync(source, target, { recursive: true });
} else {
  throw new Error("usage: node scripts/package-assets.mjs <stage|clean>");
}
