export function nodeMajor(version = process.versions.node): number {
  return Number.parseInt(version.split(".")[0] ?? "0", 10);
}

export function nodeRuntimeDiagnostic(version = process.versions.node): { ok: boolean; detail: string; fix?: string } {
  const ok = nodeMajor(version) >= 22;
  return ok
    ? { ok: true, detail: `Node ${version}` }
    : { ok: false, detail: `Node ${version} is unsupported`, fix: "activate Node 22 or newer before running factorio-codex" };
}

export function assertNodeRuntime(version = process.versions.node): void {
  const diagnostic = nodeRuntimeDiagnostic(version);
  if (!diagnostic.ok) throw new Error(`${diagnostic.detail} — ${diagnostic.fix}`);
}
