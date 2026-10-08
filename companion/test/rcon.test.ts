import net from "node:net";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MAX_REPLY_BYTES, RconClient, RconError, RconReplyLostError } from "../src/rcon.js";

const AUTH = 3;
const EXEC = 2;
const RESPONSE_VALUE = 0;
const AUTH_RESPONSE = 2;

function packet(id: number, type: number, body: string | Buffer): Buffer {
  const bodyBuf = typeof body === "string" ? Buffer.from(body, "utf8") : body;
  const buf = Buffer.alloc(14 + bodyBuf.length);
  buf.writeInt32LE(10 + bodyBuf.length, 0);
  buf.writeInt32LE(id, 4);
  buf.writeInt32LE(type, 8);
  bodyBuf.copy(buf, 12);
  return buf;
}

/** Minimal fake Factorio RCON server. `handler` maps a command to response
 *  bodies (multiple entries = multi-packet response with the same id).
 *  Faithful to Factorio 2.0.77: a zero-length command gets NO response at all;
 *  a whitespace command gets an empty response (the client relies on this for
 *  its sentinel). */
class FakeRconServer {
  private server: net.Server;
  port = 0;
  password = "secret";
  respondToAuth = true;
  responseDelayMs = 0;
  activeConnections = 0;
  /** Sentinels go unanswered (a reply cut off before its end). */
  answerSentinel = true;
  /** Close the connection after a command's first reply packet. */
  closeMidReply = false;
  handler: (cmd: string) => Array<string | Buffer> = () => [""];

  constructor() {
    this.server = net.createServer((socket) => {
      this.activeConnections++;
      socket.once("close", () => this.activeConnections--);
      let buf = Buffer.alloc(0);
      socket.on("data", (data) => {
        buf = Buffer.concat([buf, data]);
        while (buf.length >= 4) {
          const size = buf.readInt32LE(0);
          if (buf.length < 4 + size) break;
          const id = buf.readInt32LE(4);
          const type = buf.readInt32LE(8);
          const body = buf.toString("utf8", 12, 4 + size - 2);
          buf = buf.subarray(4 + size);
          if (type === AUTH) {
            if (!this.respondToAuth) continue;
            // mimic Source servers: empty RESPONSE_VALUE first, then AUTH_RESPONSE
            socket.write(packet(id, RESPONSE_VALUE, ""));
            socket.write(packet(body === this.password ? id : -1, AUTH_RESPONSE, ""));
          } else if (type === EXEC) {
            if (body === "") continue; // Factorio sends nothing back for empty commands
            if (body === " " && !this.answerSentinel) continue;
            const parts = body === " " ? [""] : this.handler(body);
            const respond = () => {
              for (const part of parts) {
                socket.write(packet(id, RESPONSE_VALUE, part));
                if (this.closeMidReply) { socket.destroy(); return; }
              }
            };
            if (body !== " " && this.responseDelayMs > 0) setTimeout(respond, this.responseDelayMs);
            else respond();
          }
        }
      });
    });
  }

  listen(): Promise<void> {
    return new Promise((resolve) => {
      this.server.listen(0, "127.0.0.1", () => {
        this.port = (this.server.address() as net.AddressInfo).port;
        resolve();
      });
    });
  }

  close(): Promise<void> {
    return new Promise((resolve) => this.server.close(() => resolve()));
  }
}

describe("RconClient", () => {
  let server: FakeRconServer;
  let client: RconClient;

  beforeEach(async () => {
    server = new FakeRconServer();
    await server.listen();
  });

  afterEach(async () => {
    client?.close();
    await server.close();
  });

  it("authenticates with the right password", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret" });
    await client.connect();
    expect(client.connected).toBe(true);
  });

  it("rejects on wrong password", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "nope" });
    await expect(client.connect()).rejects.toThrow(/auth failed/);
  });

  it("destroys the socket when authentication times out", async () => {
    server.respondToAuth = false;
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret", timeoutMs: 20 });
    await expect(client.connect()).rejects.toThrow(/auth timed out/);
    expect(client.connected).toBe(false);
    await vi.waitFor(() => expect(server.activeConnections).toBe(0));
  });

  it("executes a command and returns the response body", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret" });
    await client.connect();
    server.handler = (cmd) => (cmd === "" ? [""] : [`echo:${cmd}`]);
    await expect(client.exec("hello")).resolves.toBe("echo:hello");
  });

  it("does not let the sentinel overtake a delayed command response", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret" });
    await client.connect();
    server.responseDelayMs = 100;
    server.handler = (cmd) => [`rpc:${cmd}`];
    await expect(client.exec("enqueue")).resolves.toBe("rpc:enqueue");
  });

  it("reassembles multi-packet responses", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret" });
    await client.connect();
    const big = "x".repeat(5000);
    server.handler = (cmd) =>
      cmd === "" ? [""] : [big.slice(0, 2000), big.slice(2000, 4000), big.slice(4000)];
    await expect(client.exec("big")).resolves.toBe(big);
  });

  it("serializes concurrent commands", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret" });
    await client.connect();
    server.handler = (cmd) => (cmd === "" ? [""] : [cmd]);
    const results = await Promise.all([client.exec("a"), client.exec("b"), client.exec("c")]);
    expect(results).toEqual(["a", "b", "c"]);
  });

  it("fails cleanly when not connected", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret" });
    const error = await client.exec("x").catch((e) => e);
    expect(error).toBeInstanceOf(RconError);
    expect(error).not.toBeInstanceOf(RconReplyLostError);
  });

  it("rejects a timed-out command even when part of its reply arrived, never resolving with the fragment", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret", timeoutMs: 100 });
    await client.connect();
    server.answerSentinel = false;
    server.handler = () => ['{"ok":true,"data":{"plan'];
    const error = await client.exec("cut").catch((e) => e);
    expect(error).toBeInstanceOf(RconReplyLostError);
    expect(error.message).toBe("RCON command timed out after 100ms with 24 bytes of its reply received");
    // The connection stays usable; the old command's late packets are ignored.
    server.answerSentinel = true;
    server.handler = (cmd) => [`next:${cmd}`];
    await expect(client.exec("after")).resolves.toBe("next:after");
  });

  it("reports a connection closed mid-reply as a lost reply", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret" });
    await client.connect();
    server.closeMidReply = true;
    server.handler = () => ["first part", "second part"];
    await expect(client.exec("cut")).rejects.toThrow(RconReplyLostError);
    expect(client.connected).toBe(false);
  });

  it("joins packet bodies as bytes, so a character split across packets survives", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret" });
    await client.connect();
    const text = Buffer.from("platform \u00e9toile", "utf8");
    const cut = text.indexOf(0xc3) + 1; // inside the two-byte character
    server.handler = () => [text.subarray(0, cut), text.subarray(cut)];
    await expect(client.exec("name")).resolves.toBe("platform \u00e9toile");
  });

  it("closes the connection when one reply exceeds the byte cap", async () => {
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret" });
    await client.connect();
    const piece = "z".repeat(1024 * 1024);
    server.handler = () => [piece, piece, piece];
    const error = await client.exec("huge").catch((e) => e);
    expect(error).toBeInstanceOf(RconReplyLostError);
    expect(error.message).toBe(`RCON reply exceeded ${MAX_REPLY_BYTES} bytes`);
    expect(client.connected).toBe(false);
  });

  it("disables Nagle's algorithm on the socket", async () => {
    const noDelay = vi.spyOn(net.Socket.prototype, "setNoDelay");
    client = new RconClient({ host: "127.0.0.1", port: server.port, password: "secret" });
    await client.connect();
    expect(noDelay).toHaveBeenCalledWith(true);
    noDelay.mockRestore();
  });
});
