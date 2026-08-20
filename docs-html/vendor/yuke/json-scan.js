/**
 * Validate one JSON value while retaining only routing fields from its top-level object.
 * This mirrors a streaming decoder's skip operation for unknown notifications.
 */
export function scanEnvelope(source) {
    const scanner = new Scanner(source);
    const fields = scanner.envelope();
    scanner.space();
    if (!scanner.done)
        throw new SyntaxError("trailing data after JSON frame");
    return fields;
}
class Scanner {
    #at = 0;
    #source;
    constructor(source) {
        this.#source = source;
    }
    get done() {
        return this.#at === this.#source.length;
    }
    space() {
        while (/[ \t\r\n]/.test(this.#source[this.#at] ?? ""))
            this.#at += 1;
    }
    envelope() {
        this.space();
        this.take("{");
        this.space();
        let jsonrpc;
        let method;
        let hasId = false;
        if (this.peek("}")) {
            this.#at += 1;
            return { hasId };
        }
        for (;;) {
            const key = this.string();
            this.space();
            this.take(":");
            this.space();
            if (key === "jsonrpc" || key === "method") {
                const value = this.string();
                if (key === "jsonrpc")
                    jsonrpc = value;
                else
                    method = value;
            }
            else {
                if (key === "id")
                    hasId = true;
                this.value(0);
            }
            this.space();
            if (this.peek("}")) {
                this.#at += 1;
                break;
            }
            this.take(",");
            this.space();
        }
        return { ...(jsonrpc === undefined ? {} : { jsonrpc }), ...(method === undefined ? {} : { method }), hasId };
    }
    value(depth) {
        if (depth > 128)
            throw new SyntaxError("JSON nesting is too deep");
        this.space();
        const char = this.#source[this.#at];
        if (char === '"') {
            this.string();
            return;
        }
        if (char === "{") {
            this.object(depth + 1);
            return;
        }
        if (char === "[") {
            this.array(depth + 1);
            return;
        }
        if (char === "t")
            return this.literal("true");
        if (char === "f")
            return this.literal("false");
        if (char === "n")
            return this.literal("null");
        this.number();
    }
    object(depth) {
        this.take("{");
        this.space();
        if (this.peek("}")) {
            this.#at += 1;
            return;
        }
        for (;;) {
            this.string();
            this.space();
            this.take(":");
            this.value(depth);
            this.space();
            if (this.peek("}")) {
                this.#at += 1;
                return;
            }
            this.take(",");
            this.space();
        }
    }
    array(depth) {
        this.take("[");
        this.space();
        if (this.peek("]")) {
            this.#at += 1;
            return;
        }
        for (;;) {
            this.value(depth);
            this.space();
            if (this.peek("]")) {
                this.#at += 1;
                return;
            }
            this.take(",");
            this.space();
        }
    }
    string() {
        const start = this.#at;
        this.take('"');
        for (;;) {
            const char = this.#source[this.#at++];
            if (char === undefined || char < " ")
                throw new SyntaxError("invalid JSON string");
            if (char === '"')
                break;
            if (char !== "\\")
                continue;
            const escape = this.#source[this.#at++];
            if (escape === "u") {
                const digits = this.#source.slice(this.#at, this.#at + 4);
                if (!/^[0-9a-fA-F]{4}$/.test(digits))
                    throw new SyntaxError("invalid JSON unicode escape");
                this.#at += 4;
            }
            else if (escape === undefined || !'"\\/bfnrt'.includes(escape)) {
                throw new SyntaxError("invalid JSON escape");
            }
        }
        return JSON.parse(this.#source.slice(start, this.#at));
    }
    number() {
        const rest = this.#source.slice(this.#at);
        const token = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(rest)?.[0];
        if (token === undefined)
            throw new SyntaxError("invalid JSON value");
        this.#at += token.length;
    }
    literal(text) {
        if (!this.#source.startsWith(text, this.#at))
            throw new SyntaxError("invalid JSON literal");
        this.#at += text.length;
    }
    take(char) {
        if (!this.peek(char))
            throw new SyntaxError(`expected ${char}`);
        this.#at += 1;
    }
    peek(char) {
        return this.#source[this.#at] === char;
    }
}
//# sourceMappingURL=json-scan.js.map