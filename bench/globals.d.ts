declare var FIXTURE: string;
declare var PROJECTION_TEXT: string;
declare var PROJECTION_SESSION: string;
declare var bench: {
  start(name: string, scale: number, width: number, height: number, colors?: string): number;
  step(): number;
  verify(): number;
};
