declare module "yuke:internal/native/utf8" {
  export const utf8: {
    /** Encode a string as independent UTF-8 bytes; reject lone surrogates with TypeError. */
    encode(text: string): Uint8Array;
    /** Decode a complete byte view; reject invalid UTF-8 with TypeError and preserve NUL and BOM. */
    decode(bytes: Uint8Array): string;
  };
}
