const fs = require("node:fs");
const net = require("node:net");
const cfg = JSON.parse(fs.readFileSync("fixture.json", "utf8"));
if (cfg.mode === "exit") process.exit(23);
function packet(id, type, body = "") {
  const data = Buffer.from(body);
  const result = Buffer.alloc(14 + data.length);
  result.writeInt32LE(10 + data.length, 0);
  result.writeInt32LE(id, 4);
  result.writeInt32LE(type, 8);
  data.copy(result, 12);
  return result;
}
if (cfg.mode === "wait") setInterval(() => {}, 1000);
else {
  const server = net.createServer((socket) => {
    socket.on("error", () => {});
    let buffer = Buffer.alloc(0);
    socket.on("data", (data) => {
      buffer = Buffer.concat([buffer, data]);
      while (buffer.length >= 4 && buffer.length >= 4 + buffer.readInt32LE(0)) {
        const length = buffer.readInt32LE(0);
        const id = buffer.readInt32LE(4), type = buffer.readInt32LE(8);
        const body = buffer.toString("utf8", 12, length + 2);
        buffer = buffer.subarray(length + 4);
        if (type === 3) {
          if (cfg.mode !== "auth-stall") setTimeout(() => { if (!socket.destroyed) socket.write(packet(body === cfg.password ? id : -1, 2)); }, cfg.authDelayMs || 0);
        } else {
          fs.appendFileSync("commands", `${body}\n`);
          if (cfg.mode !== "ping-stall") socket.write(packet(id, 0, body === " " ? "" : JSON.stringify({ ok: true, data: { protocol_version: cfg.protocol, mod_version: cfg.version, factorio_version: "2.0.fixture" } })));
        }
      }
    });
  });
  server.on("error", () => process.exit(24));
  const listen = () => server.listen(cfg.port, "127.0.0.1", () => fs.writeFileSync("listening", "yes"));
  if (cfg.mode === "conflict") setTimeout(listen, cfg.conflictDelayMs || 500);
  else listen();
}
