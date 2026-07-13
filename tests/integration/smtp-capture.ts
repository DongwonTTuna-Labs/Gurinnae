import net from "node:net";

const smtpPort = Number(process.env.SMTP_CAPTURE_PORT ?? "28025");
const httpPort = Number(process.env.SMTP_CAPTURE_HTTP_PORT ?? "28087");
const messages: string[] = [];

net
  .createServer((socket) => {
    socket.setEncoding("utf8");
    socket.write("220 smtp-capture ESMTP\r\n");
    let buffer = "";
    let dataMode = false;
    let message = "";
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      while (buffer.includes("\r\n")) {
        const index = buffer.indexOf("\r\n");
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 2);
        if (dataMode) {
          if (line === ".") {
            messages.push(message);
            message = "";
            dataMode = false;
            socket.write(`250 2.0.0 queued-${messages.length}\r\n`);
          } else {
            message += `${line}\r\n`;
          }
          continue;
        }
        const command = line.toUpperCase();
        if (command.startsWith("EHLO") || command.startsWith("HELO")) {
          socket.write("250-smtp-capture\r\n250 8BITMIME\r\n");
        } else if (
          command.startsWith("MAIL FROM") ||
          command.startsWith("RCPT TO") ||
          command === "RSET"
        ) {
          socket.write("250 2.1.0 OK\r\n");
        } else if (command === "DATA") {
          dataMode = true;
          socket.write("354 End data with <CR><LF>.<CR><LF>\r\n");
        } else if (command === "QUIT") {
          socket.end("221 2.0.0 Bye\r\n");
        } else {
          socket.write("250 2.0.0 OK\r\n");
        }
      }
    });
  })
  .listen(smtpPort, "127.0.0.1");

Bun.serve({
  hostname: "127.0.0.1",
  port: httpPort,
  fetch(request) {
    if (request.method === "DELETE") {
      messages.length = 0;
      return new Response(null, { status: 204 });
    }
    return Response.json({ messages });
  },
});
