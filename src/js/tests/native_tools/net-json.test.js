import { net, utf8 } from "yuke";
import { check, equal } from "yuke:test";

// The frame limit excludes the newline and applies to bytes, not characters.
function frames(limit) {
  const buffer = new Uint8Array(limit);
  const messages = [];
  let used = 0;
  return {
    messages,
    push(chunk) {
      for (const byte of chunk) {
        if (byte === 10) {
          messages.push(JSON.parse(utf8.decode(buffer.subarray(0, used))));
          used = 0;
        } else {
          if (used === limit) throw new RangeError("frame too large");
          buffer[used++] = byte;
        }
      }
    },
    finish() {
      if (used !== 0) throw new Error("incomplete frame");
    },
  };
}

async function exchange(id, maxBytes) {
  const socket = await net.connect({ path: socketPath });
  const decoder = frames(32);
  try {
    await socket.write(utf8.encode(JSON.stringify(id) + "\n"));
    while (true) {
      const chunk = await socket.read({ maxBytes });
      if (chunk === null) break;
      decoder.push(chunk);
    }
    decoder.finish();
    return decoder.messages;
  } finally {
    socket.close();
  }
}

async function run() {
  // One chunk holds two frames and part of the next frame.
  const decoder = frames(32);
  decoder.push(utf8.encode('1\n2\n{"text":"世'));
  equal(JSON.stringify(decoder.messages), "[1,2]");
  decoder.push(utf8.encode('😀"}\n'));
  decoder.finish();
  equal(decoder.messages[2].text, "世😀");

  for (const maxBytes of [1, 4096]) {
    const result = await exchange(0, maxBytes);
    equal(JSON.stringify(result), JSON.stringify([{ text: "世😀" }, { ok: true }]));
    equal(JSON.stringify(await exchange(1, maxBytes)), JSON.stringify(["a".repeat(30)]));
    equal(JSON.stringify(await exchange(7, maxBytes)), "[]");
    for (const [id, type, message] of [
      [2, RangeError, "frame too large"],
      [3, TypeError, null],
      [4, SyntaxError, null],
      [5, Error, "incomplete frame"],
      [6, Error, "incomplete frame"],
    ]) {
      let error;
      try { await exchange(id, maxBytes); } catch (caught) { error = caught; }
      check("frame rejects with the expected error", error instanceof type);
      if (message !== null) equal(error.message, message);
    }
  }
}
run().then(() => { globalThis.socketDone = true; });
