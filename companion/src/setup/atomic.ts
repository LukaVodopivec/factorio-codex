import fs from "node:fs";
import path from "node:path";

/** Replace a text file without exposing readers to a partially-written file. */
export function atomicWriteFile(file: string, contents: string, mode?: number, replaceExisting = true): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = path.join(
    path.dirname(file),
    `.${path.basename(file)}.agentic-${process.pid}-${Date.now()}.tmp`,
  );
  try {
    fs.writeFileSync(temp, contents, { encoding: "utf8", mode });
    if (mode !== undefined) fs.chmodSync(temp, mode);
    if (replaceExisting) fs.renameSync(temp, file);
    else {
      // Publishing a complete inode by hard link is atomic and cannot clobber a destination.
      fs.linkSync(temp, file);
      fs.rmSync(temp);
    }
  } catch (error) {
    fs.rmSync(temp, { force: true });
    throw error;
  }
}
