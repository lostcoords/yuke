//! The web classes of `yuke:internal/streams`: a minimal `ReadableStream`. Many cases follow the web platform tests
//! (WPT) of `streams/readable-streams`.

use super::{NAMES, run};

/// The JavaScript of a function `tick()` that waits for one timer turn, so the earlier promise reactions and faults
/// run first.
const TICK: &str = "const tick = () => new Promise((resolve) => setTimeout(resolve, 0));";

#[tokio::test]
async fn a_reader_gives_the_queued_chunks_and_then_done() {
    let text = run::<String>(
        "a_reader_gives_the_queued_chunks_and_then_done",
        "const stream = new ReadableStream({
           start(controller) { controller.enqueue('a'); controller.enqueue('b'); controller.close(); },
         });
         const reader = stream.getReader();
         const reads = [await reader.read(), await reader.read(), await reader.read(), await reader.read()];
         await reader.closed;
         return [stream.locked, ...reads.map((read) => `${read.done}:${read.value}`)].join(' ');",
    )
    .await;

    assert_eq!(text, "true false:a false:b true:undefined true:undefined");
}

#[tokio::test]
async fn pull_fills_the_queue_up_to_the_high_water_mark_and_runs_once_at_a_time() {
    let text = run::<String>(
        "pull_fills_the_queue_up_to_the_high_water_mark_and_runs_once_at_a_time",
        &format!(
            "{TICK}
             let pulls = 0;
             let finish;
             const stream = new ReadableStream({{
               pull(controller) {{
                 pulls++;
                 return new Promise((resolve) => {{ finish = () => {{ controller.enqueue(pulls); resolve(); }}; }});
               }},
             }}, {{ highWaterMark: 2 }});
             await tick();
             const first = pulls;
             const reader = stream.getReader();
             const reads = [reader.read(), reader.read()];
             await tick();
             const waiting = pulls;
             finish();
             await tick();
             finish();
             const values = (await Promise.all(reads)).map((read) => read.value).join(',');
             await tick();
             return `${{first}} ${{waiting}} ${{values}} ${{pulls}}`;"
        ),
    )
    .await;

    // A third pull starts after the two reads take their chunks, because the queue has space again.
    assert_eq!(text, "1 1 1,2 3");
}

#[tokio::test]
async fn a_high_water_mark_of_zero_pulls_only_for_a_read() {
    let text = run::<String>(
        "a_high_water_mark_of_zero_pulls_only_for_a_read",
        &format!(
            "{TICK}
             let pulls = 0;
             const stream = new ReadableStream({{ pull(controller) {{ controller.enqueue(++pulls); }} }},
               {{ highWaterMark: 0 }});
             await tick();
             const before = pulls;
             const read = await stream.getReader().read();
             await tick();
             return `${{before}} ${{read.value}} ${{pulls}}`;"
        ),
    )
    .await;

    assert_eq!(text, "0 1 1");
}

#[tokio::test]
async fn async_iteration_gives_each_chunk_and_a_break_cancels_the_stream() {
    let text = run::<String>(
        "async_iteration_gives_each_chunk_and_a_break_cancels_the_stream",
        "const source = (chunks, seen) => ({
           start(controller) { for (const chunk of chunks) controller.enqueue(chunk); },
           cancel(reason) { seen.push(`cancel:${reason}`); },
         });
         const seen = [];
         const all = new ReadableStream({ start(controller) { controller.enqueue(1); controller.enqueue(2); controller.close(); } });
         for await (const chunk of all) seen.push(chunk);
         seen.push(all.locked);
         const broken = new ReadableStream(source([3, 4], seen));
         for await (const chunk of broken) { seen.push(chunk); break; }
         seen.push(broken.locked);
         const kept = new ReadableStream(source([5, 6], seen));
         for await (const chunk of kept.values({ preventCancel: true })) { seen.push(chunk); break; }
         seen.push((await kept.getReader().read()).value);
         return seen.join(' ');",
    )
    .await;

    assert_eq!(text, "1 2 false 3 cancel:undefined false 5 6");
}

#[tokio::test]
async fn an_iterator_return_cancels_with_its_value_and_releases_the_stream_at_once() {
    let text = run::<String>(
        "an_iterator_return_cancels_with_its_value_and_releases_the_stream_at_once",
        "let finish;
         let reason;
         const stream = new ReadableStream({
           start(controller) { controller.enqueue(1); },
           cancel(value) { reason = value; return new Promise((resolve) => { finish = resolve; }); },
         });
         const iterator = stream.values();
         const first = await iterator.next();
         const returned = iterator.return('stop');
         const next = iterator.next();
         let nextSettled = false;
         next.then(() => { nextSettled = true; });
         await new Promise((resolve) => setTimeout(resolve, 0));
         // The `next` after a `return` waits for the cancel of the source.
         const settledDuringCancel = nextSettled;
         const lockedDuringCancel = stream.locked;
         finish();
         const result = await returned;
         const after = await next;
         // A `return` behind a waiting `next` runs after it, and a later `next` waits for the `return`.
         let controller;
         const queued = new ReadableStream({ start(c) { controller = c; } }).values();
         const waiting = queued.next();
         const stopped = queued.return();
         const late = queued.next();
         controller.enqueue(2);
         controller.enqueue(3);
         const order = [(await waiting).value, (await stopped).done, (await late).done];
         return [first.value, settledDuringCancel, lockedDuringCancel, reason, result.done, result.value, after.done, ...order,
           iterator[Symbol.asyncIterator]() === iterator].join(' ');",
    )
    .await;

    assert_eq!(text, "1 false false stop true stop true 2 true true true");
}

#[tokio::test]
async fn an_error_rejects_each_waiting_read_and_the_closed_promise_without_a_fault() {
    let text = run::<String>(
        "an_error_rejects_each_waiting_read_and_the_closed_promise_without_a_fault",
        &format!(
            "{TICK}
             const reason = (promise) => promise.then(() => 'fulfilled', (error) => String(error));
             let controller;
             const stream = new ReadableStream({{ start(c) {{ controller = c; }} }});
             const reader = stream.getReader();
             const read = reason(reader.read());
             controller.error('boom');
             const results = [await read, await reason(reader.closed), await reason(reader.read()), controller.desiredSize];
             // The closed promise of a reader of an errored stream rejects, and no one reads it.
             new ReadableStream({{ start(c) {{ c.error('quiet'); }} }}).getReader();
             const failedStart = new ReadableStream({{ start() {{ return Promise.reject('start'); }} }});
             const failedPull = new ReadableStream({{ pull() {{ throw 'pull'; }} }});
             await tick();
             results.push(await reason(failedStart.getReader().read()), await reason(failedPull.getReader().read()));
             await tick();
             return results.join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "boom boom boom  start pull");
}

#[tokio::test]
async fn a_cancel_calls_the_source_once_and_ends_each_waiting_read() {
    let text = run::<String>(
        "a_cancel_calls_the_source_once_and_ends_each_waiting_read",
        &format!(
            "{TICK}
             const seen = [];
             const stream = new ReadableStream({{ cancel(reason) {{ seen.push(`cancel:${{reason}}`); }} }});
             const first = await stream.getReader().cancel('first').then(() => 'none');
             const reader = new ReadableStream({{ cancel(reason) {{ seen.push(`cancel:${{reason}}`); }} }}).getReader();
             const read = reader.read();
             await reader.cancel('second');
             seen.push((await read).done);
             await reader.cancel('third');
             const plain = await new ReadableStream().getReader().cancel().then(() => 'none');
             const lockedStream = new ReadableStream();
             lockedStream.getReader();
             seen.push(await lockedStream.cancel().then(() => 'none', (error) => error.name));
             await tick();
             return [first, plain, ...seen].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "none none cancel:first cancel:second true TypeError");
}

#[tokio::test]
async fn release_lock_rejects_each_waiting_read_and_keeps_the_queued_chunks() {
    let text = run::<String>(
        "release_lock_rejects_each_waiting_read_and_keeps_the_queued_chunks",
        &format!(
            "{TICK}
             const name = (promise) => promise.then(() => 'fulfilled', (error) => error.name);
             const stream = new ReadableStream();
             const reader = stream.getReader();
             const read = name(reader.read());
             reader.releaseLock();
             const results = [await read, await name(reader.closed), await name(reader.read()), stream.locked];
             reader.releaseLock();
             const queued = new ReadableStream({{ start(c) {{ c.enqueue('kept'); }} }});
             queued.getReader().releaseLock();
             results.push((await queued.getReader().read()).value);
             await tick();
             return results.join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "TypeError TypeError TypeError false kept");
}

#[tokio::test]
async fn enqueue_counts_the_size_of_each_chunk_against_the_high_water_mark() {
    let text = run::<String>(
        "enqueue_counts_the_size_of_each_chunk_against_the_high_water_mark",
        &format!(
            "{NAMES}
             let controller;
             new ReadableStream({{ start(c) {{ controller = c; }} }}, {{ highWaterMark: 5, size: (chunk) => chunk.length }});
             const sizes = [controller.desiredSize];
             controller.enqueue('abc');
             sizes.push(controller.desiredSize);
             let failing;
             new ReadableStream({{ start(c) {{ failing = c; }} }}, {{ size: () => -1 }});
             const thrown = names([() => failing.enqueue('x')]);
             let big;
             new ReadableStream({{ start(c) {{ big = c; }} }}, {{ size: () => 1n }});
             let thisValue = 'unset';
             let measured;
             new ReadableStream({{ start(c) {{ measured = c; }} }}, {{ size() {{ 'use strict'; thisValue = this; return 1; }} }});
             measured.enqueue('x');
             controller.close();
             sizes.push(controller.desiredSize);
             const closed = names([() => controller.enqueue('x'), () => controller.close()]);
             return [...sizes, thrown, failing.desiredSize, closed, names([() => big.enqueue('x')]), String(thisValue)].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "5 2 2 RangeError  TypeError TypeError TypeError undefined");
}

#[tokio::test]
async fn the_constructors_refuse_byte_streams_bad_strategies_and_a_locked_stream() {
    let text = run::<String>(
        "the_constructors_refuse_byte_streams_bad_strategies_and_a_locked_stream",
        &format!(
            "{NAMES}
             const locked = new ReadableStream();
             locked.getReader();
             return names([
               () => new ReadableStream({{ type: 'bytes' }}),
               () => new ReadableStream({{ type: 'other' }}),
               () => new ReadableStream({{ pull: 1 }}),
               () => new ReadableStream({{}}, {{ highWaterMark: -1 }}),
               () => new ReadableStream({{}}, {{ highWaterMark: NaN }}),
               () => new ReadableStream({{}}, {{ size: 1 }}),
               () => new ReadableStream({{}}, {{ highWaterMark: -1, size: 1 }}),
               () => new ReadableStream({{}}, {{ highWaterMark: 1n }}),
               () => new ReadableStream({{ type: 'bytes' }}, {{ highWaterMark: -1 }}),
               () => new ReadableStream(null),
               () => new ReadableStream({{ start() {{ throw new SyntaxError('x'); }} }}),
               () => new ReadableStream().getReader({{ mode: 'byob' }}),
               () => locked.getReader(),
               () => new ReadableStreamDefaultReader(locked),
               () => new ReadableStreamDefaultController(),
               () => new ReadableStreamDefaultReader(),
             ]);"
        ),
    )
    .await;

    assert_eq!(
        text,
        "TypeError TypeError TypeError RangeError RangeError TypeError TypeError TypeError TypeError TypeError \
         SyntaxError TypeError TypeError TypeError TypeError TypeError"
    );
}

#[tokio::test]
async fn each_class_names_itself_and_the_async_iterator_is_values() {
    let text = run::<String>(
        "each_class_names_itself_and_the_async_iterator_is_values",
        "let controller;
         const stream = new ReadableStream({ start(c) { controller = c; } });
         return [
           ...[stream, stream.getReader(), controller].map((value) => Object.prototype.toString.call(value)),
           ReadableStream.prototype[Symbol.asyncIterator] === ReadableStream.prototype.values,
           Object.keys(ReadableStream.prototype).includes('values'),
           Object.prototype.toString.call(new ReadableStream().values()),
         ].join(' ');",
    )
    .await;

    assert_eq!(
        text,
        "[object ReadableStream] [object ReadableStreamDefaultReader] [object ReadableStreamDefaultController] true true \
         [object ReadableStream AsyncIterator]"
    );
}
