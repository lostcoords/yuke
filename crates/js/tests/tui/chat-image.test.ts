// The paste of a large image into the composer: the session stores and sends the scaled image.

import { assertEquals, createFrame, test, waitForSettled } from "yuke:test";
import { TextEditor } from "yuke:tui";
import { fakeSessions, loadChat } from "./chat.ts";

const CRC_TABLE = Uint32Array.from({ length: 256 }, (_, n) => {
  let crc = n;
  for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? 0xed_b8_83_20 ^ (crc >>> 1) : crc >>> 1;
  return crc >>> 0;
});

function crc32(bytes: Uint8Array): number {
  let crc = 0xff_ff_ff_ff;
  for (const byte of bytes) crc = (CRC_TABLE[(crc ^ byte) & 0xff] as number) ^ (crc >>> 8);
  return (crc ^ 0xff_ff_ff_ff) >>> 0;
}

/** The PNG of a gray image whose pixels are `pixels`, row by row. The zlib stream stores the pixels as they are. */
function grayPng(width: number, height: number, pixels: Uint8Array): Uint8Array {
  const raw = new Uint8Array(height * (width + 1));
  for (let row = 0; row < height; row++)
    raw.set(pixels.subarray(row * width, (row + 1) * width), row * (width + 1) + 1);
  const blocks = Math.ceil(raw.length / 65_535);
  const zlib = new Uint8Array(2 + raw.length + blocks * 5 + 4);
  const zlibView = new DataView(zlib.buffer);
  zlib.set([0x78, 0x01]);
  let at = 2;
  for (let start = 0; start < raw.length; start += 65_535) {
    const size = Math.min(65_535, raw.length - start);
    zlib[at] = start + size === raw.length ? 1 : 0;
    zlibView.setUint16(at + 1, size, true);
    zlibView.setUint16(at + 3, ~size & 0xff_ff, true);
    zlib.set(raw.subarray(start, start + size), at + 5);
    at += 5 + size;
  }
  let low = 1;
  let high = 0;
  for (const byte of raw) {
    low = (low + byte) % 65_521;
    high = (high + low) % 65_521;
  }
  zlibView.setUint32(at, ((high << 16) | low) >>> 0);

  const chunk = (type: string, data: Uint8Array): Uint8Array => {
    const out = new Uint8Array(12 + data.length);
    const view = new DataView(out.buffer);
    view.setUint32(0, data.length);
    for (let index = 0; index < 4; index++) out[4 + index] = type.charCodeAt(index);
    out.set(data, 8);
    view.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
    return out;
  };
  const header = new Uint8Array(13);
  new DataView(header.buffer).setUint32(0, width);
  new DataView(header.buffer).setUint32(4, height);
  header.set([8, 0, 0, 0, 0], 8);
  const parts = [
    new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", zlib),
    chunk("IEND", new Uint8Array(0)),
  ];
  const png = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    png.set(part, offset);
    offset += part.length;
  }
  return png;
}

/** Paste the PNG `bytes` with ctrl+v into a chat, send it, and give the stored bytes and the inputs that the session got. */
async function pasteAndSend(bytes: Uint8Array) {
  using frame = createFrame({ width: 40, height: 6 }, undefined, { cwd: "/w", session: "s1" });
  const sessions = fakeSessions();
  const chat = await loadChat(frame, sessions);
  frame.start();
  await waitForSettled();
  frame.clipboard = { bytes, mimeType: "image/png" };
  frame.key("ctrl+v");
  await waitForSettled();
  const composer = chat.tui.widgets.list().find((mount) => mount.widget instanceof TextEditor)?.widget as TextEditor;
  const shown = composer.state.spans.map((span) => span.label);
  frame.key("enter");
  await waitForSettled();
  return { shown, stored: Uint8Array.from(sessions.blobs[0] ?? []), inputs: sessions.inputs, notices: chat.notices };
}

test("ctrl+v stores a PNG above 2000 pixels scaled down and sends the scaled image", async () => {
  const result = await pasteAndSend(grayPng(4000, 2, new Uint8Array(8000).fill(7)));
  const header = new DataView(result.stored.buffer);
  assertEquals(
    [result.shown, [header.getUint32(16), header.getUint32(20)], result.inputs, result.notices],
    [
      ["[image 1]"],
      [2000, 1],
      [[{ kind: "media", blob: { digest: "d1", len: result.stored.length }, mimeType: "image/png" }]],
      [],
    ],
  );
});
