//! The web classes of `yuke:internal/events` where a test needs the garbage collector or the faults of the runtime.
//! crates/js/tests/web/events.test.ts holds the other tests.

use rquickjs::Ctx;

use super::{evaluate, folder, next_fault, start};
use crate::Runtime;

/// Free each unreachable value, and run the finalization callbacks.
async fn collect_garbage(runtime: &Runtime) {
    runtime
        .caller
        .run(async |ctx: Ctx<'_>, _registry| {
            ctx.run_gc();
            Ok(())
        })
        .await
        .unwrap();
    evaluate::<()>(runtime, "await new Promise((resolve) => setTimeout(resolve, 0));")
        .await
        .unwrap();
}

#[tokio::test]
async fn a_listener_object_without_handle_event_is_a_fault_and_the_next_listener_runs() {
    let folder = folder("a_listener_object_without_handle_event_is_a_fault_and_the_next_listener_runs");
    let (runtime, mut faults) = start(&folder).await;

    let ran = evaluate::<bool>(
        &runtime,
        "const target = new EventTarget();
         let ran = false;
         target.addEventListener('x', {});
         target.addEventListener('x', () => { ran = true; });
         target.dispatchEvent(new Event('x'));
         return ran;",
    )
    .await
    .unwrap();

    assert!(ran);
    let fault = next_fault(&mut faults).await;
    assert_eq!(fault.name.as_deref(), Some("TypeError"));
    assert_eq!(fault.message, "the listener has no handleEvent function");
}

#[tokio::test]
async fn a_dependent_signal_with_an_abort_listener_survives_without_a_reference() {
    let folder = folder("a_dependent_signal_with_an_abort_listener_survives_without_a_reference");
    let (runtime, _faults) = start(&folder).await;
    evaluate::<()>(
        &runtime,
        "globalThis.controller = new AbortController();
         globalThis.fired = false;
         AbortSignal.any([controller.signal]).addEventListener('abort', () => { globalThis.fired = true; });",
    )
    .await
    .unwrap();

    collect_garbage(&runtime).await;
    let fired = evaluate::<bool>(&runtime, "controller.abort(); return fired;")
        .await
        .unwrap();

    assert!(fired);
}

#[tokio::test]
async fn an_unreachable_dependent_signal_without_an_abort_listener_is_collected() {
    let folder = folder("an_unreachable_dependent_signal_without_an_abort_listener_is_collected");
    let (runtime, _faults) = start(&folder).await;
    evaluate::<()>(
        &runtime,
        "globalThis.controller = new AbortController();
         globalThis.collected = [];
         globalThis.registry = new FinalizationRegistry((name) => collected.push(name));
         registry.register(AbortSignal.any([controller.signal]), 'plain');
         const removed = AbortSignal.any([controller.signal]);
         const listener = () => {};
         removed.addEventListener('abort', listener);
         removed.removeEventListener('abort', listener);
         registry.register(removed, 'removed');
         const option = AbortSignal.any([controller.signal]);
         const target = new EventTarget();
         target.addEventListener('x', listener, { signal: option });
         target.removeEventListener('x', listener);
         registry.register(option, 'option');",
    )
    .await
    .unwrap();

    collect_garbage(&runtime).await;
    let collected = evaluate::<String>(&runtime, "return collected.sort().join(' ');")
        .await
        .unwrap();

    assert_eq!(collected, "option plain removed");
}

#[tokio::test]
async fn a_throw_in_a_finalization_callback_is_a_fault_and_the_next_callback_runs() {
    let folder = folder("a_throw_in_a_finalization_callback_is_a_fault_and_the_next_callback_runs");
    let (runtime, mut faults) = start(&folder).await;
    evaluate::<()>(
        &runtime,
        "globalThis.collected = [];
         globalThis.registry = new FinalizationRegistry((name) => {
           collected.push(name);
           if (name === 'first') throw new TypeError('from a cleanup');
         });
         registry.register({}, 'first');
         registry.register({}, 'second');",
    )
    .await
    .unwrap();

    collect_garbage(&runtime).await;
    let collected = evaluate::<String>(&runtime, "return collected.sort().join(' ');")
        .await
        .unwrap();

    let shape = evaluate::<String>(
        &runtime,
        "const refused = (() => { try { new FinalizationRegistry(1); return 'none'; } catch (error) { return error.name; } })();
         const called = (() => { try { FinalizationRegistry(() => {}); return 'none'; } catch (error) { return error.name; } })();
         class Kept extends FinalizationRegistry {}
         const kept = new Kept(() => {});
         const { prototype } = FinalizationRegistry;
         return [FinalizationRegistry.name, FinalizationRegistry.length, registry instanceof FinalizationRegistry,
           Object.prototype.toString.call(registry), refused, called, kept instanceof Kept,
           Object.hasOwn(prototype, 'register'), Object.getPrototypeOf(prototype) === Object.prototype,
           prototype.constructor === FinalizationRegistry].join(' ');",
    )
    .await
    .unwrap();

    assert_eq!(next_fault(&mut faults).await.message, "from a cleanup");
    assert_eq!(collected, "first second");
    assert_eq!(
        shape,
        "FinalizationRegistry 1 true [object FinalizationRegistry] TypeError TypeError true true true true"
    );
}

#[tokio::test]
async fn an_unreachable_aborted_dependent_signal_is_collected() {
    let folder = folder("an_unreachable_aborted_dependent_signal_is_collected");
    let (runtime, _faults) = start(&folder).await;
    evaluate::<()>(
        &runtime,
        "globalThis.open = new AbortController();
         const closed = new AbortController();
         globalThis.collected = false;
         globalThis.registry = new FinalizationRegistry(() => { collected = true; });
         const signal = AbortSignal.any([open.signal, closed.signal]);
         signal.addEventListener('abort', () => {});
         registry.register(signal, 'signal');
         closed.abort();",
    )
    .await
    .unwrap();

    collect_garbage(&runtime).await;

    assert!(evaluate::<bool>(&runtime, "return collected;").await.unwrap());
}

#[tokio::test]
async fn a_dependent_signal_does_not_keep_its_sources_alive() {
    let folder = folder("a_dependent_signal_does_not_keep_its_sources_alive");
    let (runtime, _faults) = start(&folder).await;
    evaluate::<()>(
        &runtime,
        "globalThis.collected = false;
         globalThis.registry = new FinalizationRegistry(() => { collected = true; });
         const controller = new AbortController();
         controller.signal.addEventListener('abort', () => {});
         registry.register(controller.signal, 'source');
         globalThis.kept = AbortSignal.any([controller.signal]);
         kept.addEventListener('abort', () => {});",
    )
    .await
    .unwrap();

    collect_garbage(&runtime).await;

    assert!(evaluate::<bool>(&runtime, "return collected;").await.unwrap());
}

#[tokio::test]
async fn a_dependent_signal_works_on_after_one_of_its_sources_is_collected() {
    let folder = folder("a_dependent_signal_works_on_after_one_of_its_sources_is_collected");
    let (runtime, _faults) = start(&folder).await;
    evaluate::<()>(
        &runtime,
        "globalThis.live = new AbortController();
         globalThis.signal = AbortSignal.any([new AbortController().signal, live.signal]);",
    )
    .await
    .unwrap();

    collect_garbage(&runtime).await;
    let text = evaluate::<String>(
        &runtime,
        "let fired = false;
         signal.addEventListener('abort', () => { fired = true; });
         const nested = AbortSignal.any([signal]);
         live.abort('why');
         return `${fired} ${signal.reason} ${nested.reason}`;",
    )
    .await
    .unwrap();

    assert_eq!(text, "true why why");
}
