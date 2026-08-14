import { createServer } from "node:net";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

const directory = path.resolve(process.argv[2] ?? "source-rate-output");
await mkdir(directory, { recursive: true });
const server = createServer((socket) => {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length < 8) return;
    const headerLength = buffer.readUInt32BE(0);
    if (buffer.length < headerLength + 8) return;
    const report = JSON.parse(buffer.subarray(4, 4 + headerLength).toString("utf8"));
    if (report.type === "end") void writeFile(path.join(directory, "source-rate-stats.json"), JSON.stringify(report, null, 2), "utf8");
  });
});
await new Promise((resolve, reject) => server.listen(8789, "127.0.0.1", resolve).once("error", reject));
console.log(JSON.stringify({ ready: true, port: 8789 }));
process.on("SIGTERM", () => server.close(() => process.exit(0)));
