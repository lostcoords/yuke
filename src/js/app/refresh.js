// Concurrent reads share a promise that includes each requested follow-up read.
/** @template T */
export class Refresh {
  /** @param {() => Promise<unknown>} read @param {() => T} finish */
  constructor(read, finish) {
    this.read = read;
    this.finish = finish;
    /** @type {Promise<T> | null} */
    this.flight = null;
    this.again = false;
  }

  get loading() { return this.flight !== null; }

  /** @returns {Promise<T>} */
  run() {
    if (this.flight) {
      this.again = true;
      return this.flight;
    }
    return this.start();
  }

  /** @returns {Promise<T>} */
  start() {
    const flight = this.read().catch(() => {}).then(() => {
      const value = this.finish();
      if (this.again) {
        this.again = false;
        return this.start();
      }
      this.flight = null;
      return value;
    });
    this.flight = flight;
    return flight;
  }
}
