import type { ObjectSchema, Schema } from "yuke:tools";

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
      throw new Error(`Remove ${prefix}${name}. The fields are: ${names.join(", ")}.`);
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
    // A required name that the properties lack has nothing to check.
    const property = schema.properties[name];
    if (property !== undefined && !Object.hasOwn(checked, name)) {
      throw new Error(`Set ${prefix}${name} to ${expected(property)}.`);
    }
  }
  return checked;
}

function checkValue(schema: Schema, value: unknown, place: string): unknown {
  const fail = (): never => {
    throw new Error(`Set ${place} to ${expected(schema)}.`);
  };
  switch (schema.type) {
    case "string":
      if (typeof value !== "string" || !inEnum(schema.enum, value)) return fail();
      return value;
    case "boolean":
      return typeof value === "boolean" ? value : fail();
    case "integer":
    case "number": {
      if (typeof value !== "number" || !Number.isFinite(value)) return fail();
      if (schema.type === "integer" && !Number.isInteger(value)) return fail();
      if (schema.minimum !== undefined && value < schema.minimum) return fail();
      if (schema.maximum !== undefined && value > schema.maximum) return fail();
      if (!inEnum(schema.enum, value)) return fail();
      return value;
    }
    case "array":
      if (!Array.isArray(value)) return fail();
      return value.map((item: unknown, index) => checkValue(schema.items, item, `${place}[${index}]`));
    case "object":
      return isRecord(value) ? checkObject(schema, value, `${place}.`) : fail();
  }
}

/** Whether `value` is one of `values`. A schema without `enum` takes each value. */
function inEnum<T>(values: readonly T[] | undefined, value: T): boolean {
  return values === undefined || values.includes(value);
}

/** The words for what a field must hold, for example "an integer from 1 to 10" or "one of "asc", "desc"". */
function expected(schema: Schema): string {
  if ("enum" in schema && schema.enum !== undefined) {
    return `one of ${schema.enum.map((value) => JSON.stringify(value)).join(", ")}`;
  }
  switch (schema.type) {
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
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
