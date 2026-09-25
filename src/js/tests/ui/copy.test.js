import { check } from "yuke:internal/test";
import { term } from "yuke:internal/native/term";
// term.copy writes OSC 52 and returns the byte count. It refuses a payload over the cap.
check("copy-ok", term.copy("hi") === 2);
check("copy-utf8-bytes", term.copy("héllo 🙂") === 11);
check("copy-too-large", term.copy("x".repeat(term.clipboardMax + 1)) === -1);
// A non-string argument is a type error, so a stray object never reaches the clipboard.
const throws = (fn) => { try { fn(); return false; } catch (e) { return true; } };
check("copy-number", throws(() => term.copy(42)));
check("copy-null", throws(() => term.copy(null)));
check("copy-object", throws(() => term.copy({ toString: () => "x" })));
