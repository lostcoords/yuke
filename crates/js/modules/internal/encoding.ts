/** The web classes `TextEncoder` and `TextDecoder`, for UTF-8 only. `yuke:internal/web` installs them as globals. */
import { decodeText, encodeText, encodeTextInto } from "yuke:internal/native";
import { bytesOf, checkUint8Array, dictionary, domString, usvString, webClass } from "yuke:internal/webidl";

/** The labels of UTF-8 in the Encoding Standard. */
const UTF8_LABELS = ["unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8"];

export class TextEncoder {
  // The field gives the brand check: a method call on another object throws a `TypeError`.
  readonly #encoding = "utf-8";

  get encoding(): "utf-8" {
    return this.#encoding;
  }

  encode(input: unknown = ""): Uint8Array {
    if (!(#encoding in this)) throw new TypeError("the value is not a TextEncoder");
    return encodeText(usvString(input));
  }

  encodeInto(...args: [source: string, destination: Uint8Array]): { read: number; written: number } {
    if (!(#encoding in this)) throw new TypeError("the value is not a TextEncoder");
    const source = usvString(args[0]);
    // A missing destination fails this check with a `TypeError` too.
    const destination: unknown = args[1];
    checkUint8Array(destination, "the destination");
    // A detached destination has the length 0, so the encoder writes nothing.
    const { bytes, read } = encodeTextInto(source, destination.length);
    if (bytes.length > 0) destination.set(bytes);
    return { read, written: bytes.length };
  }
}

export class TextDecoder {
  readonly #fatal: boolean;
  readonly #ignoreBOM: boolean;
  /** The bytes of an incomplete sequence at the end of the last `decode` with `stream`. */
  #pending: Uint8Array = new Uint8Array(0);
  /** The decoder has given its first character, so a later U+FEFF is text, not a byte order mark. */
  #started = false;

  constructor(label: unknown = "utf-8", options?: { readonly fatal?: boolean; readonly ignoreBOM?: boolean }) {
    // The Encoding Standard trims ASCII whitespace and ignores the case of a label.
    const name = domString(label)
      .replace(/^[\t\n\f\r ]+|[\t\n\f\r ]+$/g, "")
      .toLowerCase();
    if (!UTF8_LABELS.includes(name)) {
      throw new RangeError(`the encoding '${name}' is not supported: TextDecoder decodes UTF-8 only`);
    }
    const fields = dictionary(options, "the options");
    this.#fatal = Boolean(fields.fatal);
    this.#ignoreBOM = Boolean(fields.ignoreBOM);
  }

  get encoding(): "utf-8" {
    if (!(#fatal in this)) throw new TypeError("the value is not a TextDecoder");
    return "utf-8";
  }

  get fatal(): boolean {
    return this.#fatal;
  }

  get ignoreBOM(): boolean {
    return this.#ignoreBOM;
  }

  /** Decode `input`. With `stream: true`, an incomplete sequence at the end waits for the next call. */
  decode(input?: unknown, options?: { readonly stream?: boolean }): string {
    const fresh = input === undefined ? new Uint8Array(0) : bytesOf(input, "the input");
    const stream = Boolean(dictionary(options, "the options").stream);
    const bytes = this.#pending.length === 0 ? fresh : join(this.#pending, fresh);
    let result: { readonly text: string; readonly rest: number };
    try {
      result = decodeText(bytes, this.#fatal, stream);
    } catch (error) {
      this.#reset();
      throw error;
    }
    this.#pending = result.rest === 0 ? new Uint8Array(0) : new Uint8Array(bytes.subarray(bytes.length - result.rest));
    let text = result.text;
    if (!this.#started && text.length > 0) {
      this.#started = true;
      if (!this.#ignoreBOM && text.startsWith("﻿")) text = text.slice(1);
    }
    if (!stream) this.#reset();
    return text;
  }

  #reset(): void {
    this.#pending = new Uint8Array(0);
    this.#started = false;
  }
}

function join(first: Uint8Array, second: Uint8Array): Uint8Array {
  const bytes = new Uint8Array(first.length + second.length);
  bytes.set(first);
  bytes.set(second, first.length);
  return bytes;
}

webClass(TextEncoder, "TextEncoder");
webClass(TextDecoder, "TextDecoder");
