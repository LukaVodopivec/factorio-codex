import fs from "node:fs";
import path from "node:path";

/** Replace a text file without exposing readers to a partially-written file. */
export function atomicWriteFile(file: string, contents: string, mode?: number): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = path.join(
    path.dirname(file),
    `.${path.basename(file)}.agentic-${process.pid}-${Date.now()}.tmp`,
  );
  try {
    fs.writeFileSync(temp, contents, { encoding: "utf8", mode });
    if (mode !== undefined) fs.chmodSync(temp, mode);
    fs.renameSync(temp, file);
  } catch (error) {
    fs.rmSync(temp, { force: true });
    throw error;
  }
}
