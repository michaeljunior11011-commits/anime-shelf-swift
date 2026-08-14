import { createServer } from "node:net";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

const directory = path.resolve(process.argv[2] ?? "jpeg-benchmark-output");
await mkdir(directory, { recursive: true });
let complete = false;
let report;

function parse(socket) {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 8) {
      const headerLength = buffer.readUInt32BE(0);
      if (headerLength > 1024 * 1024 || buffer.length < headerLength + 8) return;
      const header = JSON.parse(buffer.subarray(4, 4 + headerLength).toString("utf8"));
      const bodyLength = buffer.readUInt32BE(4 + headerLength);
      const packetLength = headerLength + 8 + bodyLength;
      if (buffer.length < packetLength) return;
      buffer = buffer.subarray(packetLength);
      if (header.type === "end") {
        report = header; complete = true;
        void writeFile(path.join(directory, "jpeg-benchmark-stats.json"), JSON.stringify(header, null, 2), "utf8");
      }
    }
  });
}

const server = createServer(parse);
await new Promise((resolve, reject) => server.listen(8788, "127.0.0.1", resolve).once("error", reject));
console.log(JSON.stringify({ ready: true, port: 8788 }));
process.on("SIGTERM", () => server.close(() => process.exit(0)));
process.on("SIGINT", () => server.close(() => process.exit(0)));
setInterval(() => console.log(JSON.stringify({ complete, report })), 5000).unref();
