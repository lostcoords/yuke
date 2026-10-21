/**
 * A JSON schema of a value, in the subset that yuke checks:
 * - Each type takes only the keywords of its schema below. Another keyword fails the definition of the tool.
 * - An object is closed: a field outside `properties` is an error.
 * - A `null` field that `required` does not name counts as absent, because a model sends `null` for a field that it
 *   leaves out.
 * - `enum` lists each value that a string, an integer, or a number can take.
 */
export type Schema = ScalarSchema | ArraySchema | ObjectSchema;

/**
 * A string, a boolean, or a number. An integer or a number can have `minimum` and `maximum`. A string or a number can
 * have `enum`: a list of values of its type, each once.
 */
export type ScalarSchema =
  | { readonly type: "boolean"; readonly description?: string }
  | { readonly type: "string"; readonly description?: string; readonly enum?: readonly string[] }
  | {
      readonly type: "integer" | "number";
      readonly description?: string;
      readonly minimum?: number;
      readonly maximum?: number;
      readonly enum?: readonly number[];
    };

/** An array of `items`. */
export interface ArraySchema {
  readonly type: "array";
  readonly items: Schema;
  readonly description?: string;
}

/** An object. A field outside `properties` is an error, with or without `additionalProperties: false`. */
export interface ObjectSchema {
  readonly type: "object";
  readonly properties: Readonly<Record<string, Schema>>;
  readonly required?: readonly string[];
  readonly additionalProperties?: false;
  readonly description?: string;
}

/**
 * The arguments that `execute` gets for the schema `S`, after the check. A field that `required` does not name can be
 * missing. An inline schema keeps its fields, and so does a constant with `as const satisfies ObjectSchema`.
 */
export type Infer<S extends ObjectSchema> = string extends keyof S["properties"]
  ? Record<string, unknown>
  : Flat<
      {
        -readonly [K in keyof S["properties"] as K extends RequiredNames<S> ? K : never]-?: Value<S["properties"][K]>;
      } & {
        -readonly [K in keyof S["properties"] as K extends RequiredNames<S> ? never : K]?: Value<S["properties"][K]>;
      }
    >;

/** The names in `required` of `S`. A `required` that is a `string[]` names no field for certain. */
type RequiredNames<S extends ObjectSchema> = S extends { readonly required: infer R extends readonly string[] }
  ? number extends R["length"]
    ? never
    : R[number]
  : never;

/** The value of a field with the schema `S`. */
type Value<S extends Schema> = Schema extends S
  ? unknown
  : S extends { readonly type: "array"; readonly items: infer T extends Schema }
    ? Value<T>[]
    : S extends ObjectSchema
      ? Infer<S>
      : S extends { readonly enum: readonly (infer E)[] }
        ? E
        : S extends { readonly type: infer T extends keyof Scalars }
          ? Scalars[T]
          : never;

/** The value of each scalar type. A union of types, such as `"string" | "boolean"`, gives the union of values. */
interface Scalars {
  string: string;
  boolean: boolean;
  integer: number;
  number: number;
}

/** `T` as one object type, so an editor shows its fields. */
type Flat<T> = { [K in keyof T]: T[K] };

/** A media item beside the text of a result, for example an image. It comes from a file or from bytes. */
export type ToolMedia = {
  /** The media type, for example `image/png`. */
  readonly mimeType: string;
} & (
  | {
      /**
       * The path of the file. In a tool result, a relative path starts in the workspace folder of the call. In a
       * `tool.after` answer, it starts in the workspace folder of the session.
       */
      readonly path: string;
      readonly bytes?: never;
    }
  | {
      /** The bytes. yuke copies them when `execute` returns. */
      readonly bytes: Uint8Array;
      readonly path?: never;
    }
);

/** The result of a call: the text for the model, with media or without. */
export type ToolResult =
  | string
  | {
      /** The text for the model. It can be empty when the result has media. */
      readonly text: string;
      readonly media?: readonly ToolMedia[] | undefined;
      /** `true` makes the result an error. The model still gets the text and the media. The default is `false`. */
      readonly isError?: boolean | undefined;
    };

/** What a call gives its tool besides the arguments. */
export interface ToolContext {
  /** The id of the session of the call. */
  readonly sessionId: string;
  /** The id of the call. It is unique in its session only. */
  readonly callId: string;
  /**
   * The workspace folder of the call: the folder of the session at the start of the call. Relative paths and commands
   * start here.
   */
  readonly folder: string;
  /**
   * Aborts when the turn cancels the call, and when the call ends. The reason is a `DOMException` named `AbortError`.
   * After a cancel, the host still waits until `execute` settles. Its result goes into the context of the session, and
   * then the turn ends. Thus `execute` must stop its work when the signal aborts.
   */
  readonly signal: AbortSignal;
  /** Show `text` to the user while the call runs. The model does not receive it. */
  readonly output: (this: void, text: string) => void;
}

/**
 * A tool that the model can call. yuke checks the arguments against `parameters` before `execute`. A throw of `execute`
 * is an error result with the message of the error.
 */
export interface Tool<S extends ObjectSchema = ObjectSchema> {
  /**
   * The name of the tool. It matches `^[a-zA-Z0-9_-]{1,64}$`, the rule of the providers. Another form, a name that the
   * session already has, or a name that yuke reserves, throws a `TypeError`.
   */
  readonly name: string;
  /** When the model uses the tool, and what the tool does. */
  readonly description: string;
  /** The schema of the arguments. */
  readonly parameters: S;
  /**
   * `serial` runs each call alone among the calls of one model answer. `parallel` runs the call together with the
   * other parallel calls of that answer. Neither waits for the calls of other sessions.
   */
  readonly concurrency: "serial" | "parallel";
  /**
   * `true` keeps the tool out of each request until the model finds it with the tool search. Use it for a tool that
   * the model rarely needs. The default is `false`.
   */
  readonly deferLoading?: boolean | undefined;
  readonly execute: (this: void, args: Infer<S>, context: ToolContext) => ToolResult | Promise<ToolResult>;
}
