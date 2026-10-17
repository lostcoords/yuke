import type { ObjectSchema, Schema } from "yuke:tools";

/** The keywords of each type. A schema with another keyword has a part that no check covers, so it fails. */
const KEYWORDS: Readonly<Record<Schema["type"], readonly string[]>> = {
  string: ["type", "description"],
  integer: ["type", "description", "minimum", "maximum"],
  number: ["type", "description", "minimum", "maximum"],
  boolean: ["type", "description"],
  array: ["type", "description", "items"],
  object: ["type", "description", "properties", "required", "additionalProperties"],
};

/** Throw a `TypeError` when `schema` is not an object schema, or uses a part of JSON schema that `checkArguments` does not check. */
export function checkParameters(schema: unknown): asserts schema is ObjectSchema {
  checkSchema(schema, "parameters");
  if (schema.type !== "object") throw new TypeError("parameters.type is not object");
}

function checkSchema(schema: unknown, place: string): asserts schema is Schema {
  if (!isRecord(schema)) throw new TypeError(`${place} is not a schema object`);
  const type = schema.type;
  if (typeof type !== "string" || !Object.hasOwn(KEYWORDS, type)) {
    throw new TypeError(`${place}.type is not one of ${Object.keys(KEYWORDS).join(", ")}`);
  }
  const keywords = KEYWORDS[type as Schema["type"]];
  for (const keyword of Object.keys(schema)) {
    if (!keywords.includes(keyword)) throw new TypeError(`${place}: yuke does not check the keyword '${keyword}'`);
  }
  if (schema.description !== undefined && typeof schema.description !== "string") {
    throw new TypeError(`${place}.description is not a string`);
  }
  for (const bound of ["minimum", "maximum"]) {
    if (schema[bound] !== undefined && !Number.isFinite(schema[bound])) {
      throw new TypeError(`${place}.${bound} is not a finite number`);
    }
  }
  if (type === "array") checkSchema(schema.items, `${place}.items`);
  if (type === "object") {
    const properties = schema.properties;
    if (!isRecord(properties)) throw new TypeError(`${place}.properties is not an object`);
    for (const [name, property] of Object.entries(properties)) checkSchema(property, `${place}.properties.${name}`);
    const required = schema.required === undefined ? [] : schema.required;
    if (
      !Array.isArray(required) ||
      !required.every((name) => typeof name === "string" && Object.hasOwn(properties, name))
    ) {
      throw new TypeError(`${place}.required names a field that properties does not have`);
    }
    if (schema.additionalProperties !== undefined && schema.additionalProperties !== false) {
      throw new TypeError(`${place}.additionalProperties is not false`);
    }
  }
}

/**
 * The arguments `value` after a check against `schema`. A `null` field that is not required counts as absent, because
 * a model sends `null` for a field that it leaves out. A failure throws an error whose message tells the model what
 * to change.
 */
export function checkArguments(schema: ObjectSchema, value: unknown): Record<string, unknown> {
  if (!isRecord(value)) throw new Error("Pass the arguments as a JSON object.");
  return checkObject(schema, value, "");
}

function checkObject(schema: ObjectSchema, value: Record<string, unknown>, prefix: string): Record<string, unknown> {
  const names = Object.keys(schema.properties);
  const required = schema.required ?? [];
  const checked: Record<string, unknown> = {};
  for (const [name, field] of Object.entries(value)) {
    // An own property only, so a name such as `toString` does not find a function of the prototype.
    const property = Object.hasOwn(schema.properties, name) ? schema.properties[name] : undefined;
    if (property === undefined) {
      throw new Error(`Remove ${prefix}${name}. The arguments are: ${names.join(", ")}.`);
    }
    if (field === null && !required.includes(name)) continue;
    // An assignment to `__proto__` would set the prototype, so each field becomes an own property.
    Object.defineProperty(checked, name, {
      value: checkValue(property, field, `${prefix}${name}`),
      enumerable: true,
      writable: true,
      configurable: true,
    });
  }
  for (const name of required) {
    if (!Object.hasOwn(checked, name)) throw new Error(`Set ${prefix}${name} to ${expected(schema.properties[name])}.`);
  }
  return checked;
}

function checkValue(schema: Schema, value: unknown, place: string): unknown {
  const fail = (): never => {
    throw new Error(`Set ${place} to ${expected(schema)}.`);
  };
  switch (schema.type) {
    case "string":
      return typeof value === "string" ? value : fail();
    case "boolean":
      return typeof value === "boolean" ? value : fail();
    case "integer":
    case "number": {
      if (typeof value !== "number" || !Number.isFinite(value)) return fail();
      if (schema.type === "integer" && !Number.isInteger(value)) return fail();
      if (schema.minimum !== undefined && value < schema.minimum) return fail();
      if (schema.maximum !== undefined && value > schema.maximum) return fail();
      return value;
    }
    case "array":
      if (!Array.isArray(value)) return fail();
      return value.map((item: unknown, index) => checkValue(schema.items, item, `${place}[${index}]`));
    case "object":
      return isRecord(value) ? checkObject(schema, value, `${place}.`) : fail();
  }
}

/** The words for what a field must hold, for example "an integer from 1 to 10". */
function expected(schema: Schema | undefined): string {
  switch (schema?.type) {
    case "string":
      return "a string";
    case "boolean":
      return "true or false";
    case "integer":
    case "number": {
      const kind = schema.type === "integer" ? "an integer" : "a number";
      if (schema.minimum !== undefined && schema.maximum !== undefined) {
        return `${kind} from ${schema.minimum} to ${schema.maximum}`;
      }
      if (schema.minimum !== undefined) return `${kind} of at least ${schema.minimum}`;
      if (schema.maximum !== undefined) return `${kind} of at most ${schema.maximum}`;
      return kind;
    }
    case "array":
      return "an array";
    case "object":
      return "an object";
    case undefined:
      return "a value";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
