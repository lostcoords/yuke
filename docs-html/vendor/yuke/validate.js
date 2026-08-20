import { WIRE_MODEL } from "./generated/wire-model.js";
const MODEL = WIRE_MODEL;
const STRUCTURES = new Map(MODEL.structures.map((item) => [item.name, item]));
const UNIONS = new Map(MODEL.unions.map((item) => [item.name, item]));
const ENUMS = new Map(MODEL.enumerations.map((item) => [item.name, item]));
const ALIASES = new Map(MODEL.aliases.map((item) => [item.name, item]));
const METHODS = new Map(MODEL.methods.map((item) => [item.name, item]));
const BROADCASTS = new Map(MODEL.broadcasts.map((item) => [item.name, item]));
const UTF8 = new TextEncoder();
/** A value did not match the generated wire model. */
export class WireValidationError extends TypeError {
    path;
    detail;
    constructor(path, detail) {
        super(`${path}: ${detail}`);
        this.name = "WireValidationError";
        this.path = path;
        this.detail = detail;
    }
}
function fail(path, detail) {
    throw new WireValidationError(path, detail);
}
function object(value, path) {
    if (typeof value !== "object" || value === null || Array.isArray(value))
        fail(path, "expected an object");
    return value;
}
function checkBound(value, bound, path) {
    if (bound === undefined || bound.kind === "unbounded")
        return;
    const length = typeof value === "string" ? UTF8.encode(value).byteLength : value.length;
    if (bound.kind === "bounded" && length > bound.value)
        fail(path, `length ${length} exceeds ${bound.value}`);
    if (bound.kind === "fixed" && length !== bound.value)
        fail(path, `length ${length} must equal ${bound.value}`);
}
function integerRange(type) {
    const safe = MODEL.constants.MAX_WIRE_INTEGER ?? Number.MAX_SAFE_INTEGER;
    switch (type) {
        case "u64": return [0, safe];
        case "u32": return [0, Math.min(safe, 0xffff_ffff)];
        case "u16": return [0, 0xffff];
        case "u8": return [0, 0xff];
        case "i32": return [-0x8000_0000, 0x7fff_ffff];
        case "i16": return [-0x8000, 0x7fff];
        case "i8": return [-0x80, 0x7f];
        default: return [-safe, safe];
    }
}
function validateField(field, owner, path) {
    const present = Object.prototype.hasOwnProperty.call(owner, field.name);
    const fieldPath = `${path}.${field.name}`;
    if (!present) {
        if (field.presence === "required" || field.presence === "requiredNullable")
            fail(fieldPath, "required member is missing");
        return;
    }
    const value = owner[field.name];
    if (field.presence === "requiredNullable" && value === null)
        return;
    if (field.presence === "tristate" && value === null)
        return;
    if (value === null)
        fail(fieldPath, "null is not allowed");
    if (field.constValue !== undefined && value !== field.constValue) {
        fail(fieldPath, `expected constant ${field.constValue}`);
    }
    if (field.presence === "tristate") {
        const union = UNIONS.get(field.type);
        const valueArm = union?.arms.find((arm) => arm.form === "value");
        if (valueArm?.wireType === undefined)
            fail(fieldPath, "tristate has no value arm");
        validateType(valueArm.wireType, value, field.bound, fieldPath);
        return;
    }
    validateType(field.type, value, field.bound, fieldPath);
}
function validateNamed(name, value, path) {
    const alias = ALIASES.get(name);
    if (alias !== undefined) {
        validateType(alias.base, value, alias.bound, path);
        return;
    }
    const enumeration = ENUMS.get(name);
    if (enumeration !== undefined) {
        const allowed = enumeration.values.map((item) => enumeration.numeric ? Number(item.wire) : item.wire);
        if (!allowed.includes(value))
            fail(path, `unknown ${name} value`);
        return;
    }
    const structure = STRUCTURES.get(name);
    if (structure !== undefined) {
        const record = object(value, path);
        for (const field of structure.fields)
            validateField(field, record, path);
        return;
    }
    const union = UNIONS.get(name);
    if (union === undefined)
        fail(path, `unknown wire type ${name}`);
    if (union.discriminator !== "") {
        const record = object(value, path);
        const tag = record[union.discriminator];
        const arm = union.arms.find((candidate) => candidate.tag === tag);
        if (arm === undefined)
            fail(`${path}.${union.discriminator}`, `unknown ${name} discriminator`);
        validateNamed(arm.type, value, path);
        return;
    }
    const failures = [];
    for (const arm of union.arms) {
        try {
            validateNamed(arm.type, value, path);
            return;
        }
        catch (error) {
            if (error instanceof WireValidationError)
                failures.push(error);
            else
                throw error;
        }
    }
    fail(path, failures[0]?.detail ?? `does not match ${name}`);
}
function validateType(expression, value, bound, path) {
    const maybe = /^Maybe\((.*)\)$/.exec(expression);
    if (maybe?.[1] !== undefined) {
        validateType(maybe[1], value, bound, path);
        return;
    }
    if (expression.startsWith("[]")) {
        if (!Array.isArray(value))
            fail(path, "expected an array");
        checkBound(value, bound, path);
        for (let index = 0; index < value.length; index += 1)
            validateType(expression.slice(2), value[index], undefined, `${path}[${index}]`);
        return;
    }
    const fixed = /^\[(\d+)\]u8$/.exec(expression);
    if (fixed?.[1] !== undefined) {
        const digits = Number(fixed[1]);
        if (typeof value !== "string" || !new RegExp(`^[0-9a-f]{${digits}}$`).test(value))
            fail(path, `expected ${digits} lowercase hex characters`);
        return;
    }
    if (expression === "string") {
        if (typeof value !== "string")
            fail(path, "expected a string");
        checkBound(value, bound, path);
        return;
    }
    if (expression === "bool") {
        if (typeof value !== "boolean")
            fail(path, "expected a boolean");
        return;
    }
    if (expression === "f32" || expression === "f64") {
        if (typeof value !== "number" || !Number.isFinite(value))
            fail(path, "expected a finite number");
        return;
    }
    if (/^(?:u|i)(?:8|16|32|64)$/.test(expression) || expression === "int") {
        if (typeof value !== "number" || !Number.isSafeInteger(value))
            fail(path, "expected a safe integer");
        const [minimum, maximum] = integerRange(expression);
        if (value < minimum || value > maximum)
            fail(path, `integer is outside ${expression} range`);
        return;
    }
    validateNamed(expression, value, path);
}
/** Validate request params from untyped JavaScript before sending them. */
export function assertParams(method, params) {
    const entry = METHODS.get(method);
    if (entry === undefined)
        fail("method", `unknown request method ${method}`);
    if (params === undefined && entry.paramsOptional)
        return;
    if (params === undefined)
        fail("params", "required request params are missing");
    validateNamed(entry.params, params, "params");
}
/** Validate a success result using the pending request's method. */
export function assertResult(method, result) {
    const entry = METHODS.get(method);
    if (entry === undefined)
        fail("method", `unknown request method ${method}`);
    validateNamed(entry.result, result, "result");
}
/** Validate a known broadcast payload before delivering it to application code. */
export function assertBroadcast(method, params) {
    const entry = BROADCASTS.get(method);
    if (entry === undefined)
        fail("method", `unknown broadcast method ${method}`);
    validateNamed(entry.params, params, "params");
}
//# sourceMappingURL=validate.js.map