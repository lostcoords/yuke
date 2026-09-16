declare var FIXTURE: string;
declare var PROJECTION_TEXT: string;
declare var PROJECTION_SESSION: string;
declare var bench: {
  start(name: string, scale: number, width: number, height: number, colors?: string): number | Promise<number>;
  step(): number | Promise<number>;
  verify(): number;
};

declare var AGENTS_ROOT: string;
declare var AGENTS_TARGET: string;
declare var agentReads: () => { gets: number; lists: number; updates: number };
declare var agentResetReads: () => number;
