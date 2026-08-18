import { sendStreamingRequest } from "./lib/api";
const vmId = process.argv[2]!;
let bytes = 0, esc = 0, first = "";
const { exitCode } = await sendStreamingRequest(
  { method: "vm.execStream", params: { vmId, user: "admin", waitForAgent: true, tty: true, rows: 24, cols: 80, term: "xterm-256color", command: "vi /tmp/probe.txt" } },
  (c) => {
    if (!c.data) return;
    const b = c.encoding === "base64" ? Buffer.from(c.data, "base64") : Buffer.from(c.data);
    bytes += b.length;
    esc += (b.toString("latin1").match(/\x1b/g) ?? []).length;
    if (!first) first = JSON.stringify(b.toString("latin1").slice(0, 120));
  },
  { timeoutMs: 30_000, onOpen: (send) => {
      const key = (s: string) => send({ type: "stdin", data: Buffer.from(s, "latin1").toString("base64") });
      setTimeout(() => key("iHELLO"), 1500);
      setTimeout(() => key("\x1b"), 2500);
      setTimeout(() => key(":wq\n"), 3000);
  } }
);
console.log("bytes:", bytes, "escape sequences:", esc);
console.log("first output:", first);
console.log("exitCode:", exitCode);
