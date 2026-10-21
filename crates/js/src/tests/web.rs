//! The web classes of `yuke:internal/events`: events, event targets, and abort signals. Many cases follow the web
//! platform tests (WPT) of `dom/events` and `dom/abort`.

use rquickjs::Ctx;

use super::{NAMES, evaluate, folder, next_fault, run, start};
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
async fn the_web_classes_are_globals_that_a_script_can_replace() {
    let text = run::<String>(
        "the_web_classes_are_globals_that_a_script_can_replace",
        "return ['AbortController', 'AbortSignal', 'CustomEvent', 'Event', 'EventTarget'].map((name) => {
           const { writable, enumerable, configurable, value } = Object.getOwnPropertyDescriptor(globalThis, name);
           return `${value.name}:${writable}${enumerable}${configurable}`;
         }).join(' ');",
    )
    .await;

    assert_eq!(
        text,
        "AbortController:truefalsetrue AbortSignal:truefalsetrue CustomEvent:truefalsetrue Event:truefalsetrue \
         EventTarget:truefalsetrue"
    );
}

#[tokio::test]
async fn each_class_names_itself_in_its_string_form() {
    let text = run::<String>(
        "each_class_names_itself_in_its_string_form",
        "const controller = new AbortController();
         return [new Event('x'), new CustomEvent('x'), new EventTarget(), controller.signal, controller]
           .map((value) => Object.prototype.toString.call(value)).join(' ');",
    )
    .await;

    assert_eq!(
        text,
        "[object Event] [object CustomEvent] [object EventTarget] [object AbortSignal] [object AbortController]"
    );
}

#[tokio::test]
async fn an_event_needs_a_type_and_an_init_that_is_an_object() {
    let text = run::<String>(
        "an_event_needs_a_type_and_an_init_that_is_an_object",
        &format!(
            "{NAMES}
             return [
               names([() => new Event(), () => new Event('x', 1), () => new Event(Symbol()), () => new CustomEvent()]),
               new Event(undefined).type,
               new Event('x', null).bubbles,
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "TypeError TypeError TypeError TypeError undefined false");
}

#[tokio::test]
async fn an_event_takes_its_flags_from_the_init() {
    let text = run::<String>(
        "an_event_takes_its_flags_from_the_init",
        "const plain = new Event('x');
         const set = new Event('x', { bubbles: 1, cancelable: 'yes', composed: {} });
         return [plain.bubbles, plain.cancelable, plain.composed, set.bubbles, set.cancelable, set.composed].join(' ');",
    )
    .await;

    assert_eq!(text, "false false false true true true");
}

#[tokio::test]
async fn a_custom_event_carries_its_detail() {
    let text = run::<String>(
        "a_custom_event_carries_its_detail",
        "const detail = { path: 'a' };
         return [
           new CustomEvent('x', { detail }).detail === detail,
           new CustomEvent('x').detail,
           new CustomEvent('x', { detail: undefined }).detail,
           new CustomEvent('x', { bubbles: true }).bubbles,
           new CustomEvent('x') instanceof Event,
         ].map(String).join(' ');",
    )
    .await;

    assert_eq!(text, "true null null true true");
}

#[tokio::test]
async fn a_subclass_of_event_reaches_a_listener_of_a_subclass_of_event_target() {
    let text = run::<String>(
        "a_subclass_of_event_reaches_a_listener_of_a_subclass_of_event_target",
        "class Saved extends Event { constructor(path) { super('saved'); this.path = path; } }
         class Notes extends EventTarget {}
         const notes = new Notes();
         let seen = '';
         notes.addEventListener('saved', (event) => { seen = `${event.path} ${event instanceof Saved}`; });
         notes.dispatchEvent(new Saved('a.txt'));
         return seen;",
    )
    .await;

    assert_eq!(text, "a.txt true");
}

#[tokio::test]
async fn a_dispatch_sets_the_targets_and_the_phase_only_while_it_runs() {
    let text = run::<String>(
        "a_dispatch_sets_the_targets_and_the_phase_only_while_it_runs",
        "const target = new EventTarget();
         const event = new Event('x');
         let seen = [];
         target.addEventListener('x', function (event) {
           const path = event.composedPath();
           seen = [this === target, event.target === target, event.currentTarget === target, event.eventPhase,
             path.length === 1 && path[0] === target];
         });
         target.dispatchEvent(event);
         return [...seen, event.target === target, event.currentTarget, event.eventPhase, event.composedPath().length]
           .map(String).join(' ');",
    )
    .await;

    assert_eq!(text, "true true true 2 true true null 0 0");
}

#[tokio::test]
async fn an_event_names_its_phases_on_the_class_and_on_each_event() {
    let text = run::<String>(
        "an_event_names_its_phases_on_the_class_and_on_each_event",
        "const event = new Event('x');
         const names = ['NONE', 'CAPTURING_PHASE', 'AT_TARGET', 'BUBBLING_PHASE'];
         const fixed = names.every((name) => [Event, Event.prototype].every((owner) => {
           const { writable, enumerable, configurable } = Object.getOwnPropertyDescriptor(owner, name);
           return !writable && enumerable && !configurable;
         }));
         return [...names.map((name) => Event[name]), ...names.map((name) => event[name]), fixed].join(' ');",
    )
    .await;

    assert_eq!(text, "0 1 2 3 0 1 2 3 true");
}

#[tokio::test]
async fn capture_listeners_run_before_the_other_listeners() {
    let text = run::<String>(
        "capture_listeners_run_before_the_other_listeners",
        "const target = new EventTarget();
         const log = [];
         target.addEventListener('x', () => log.push('other'));
         target.addEventListener('x', () => log.push('capture'), true);
         target.addEventListener('x', () => log.push('capture2'), { capture: true });
         target.dispatchEvent(new Event('x'));
         return log.join(' ');",
    )
    .await;

    assert_eq!(text, "capture capture2 other");
}

#[tokio::test]
async fn stop_propagation_ends_the_dispatch_after_its_pass_and_resets_after_a_dispatch() {
    let text = run::<String>(
        "stop_propagation_ends_the_dispatch_after_its_pass_and_resets_after_a_dispatch",
        "const target = new EventTarget();
         const log = [];
         target.addEventListener('x', (event) => { log.push('capture'); event.stopPropagation(); }, true);
         target.addEventListener('x', () => log.push('capture2'), true);
         target.addEventListener('x', () => log.push('other'));
         const event = new Event('x');
         target.dispatchEvent(event);
         target.dispatchEvent(event);
         const early = new Event('x');
         early.stopPropagation();
         log.push('|');
         target.dispatchEvent(early);
         log.push('|');
         target.dispatchEvent(early);
         return log.join(' ');",
    )
    .await;

    assert_eq!(text, "capture capture2 capture capture2 | | capture capture2");
}

#[tokio::test]
async fn stop_immediate_propagation_ends_the_dispatch_after_its_listener() {
    let text = run::<String>(
        "stop_immediate_propagation_ends_the_dispatch_after_its_listener",
        "const target = new EventTarget();
         const log = [];
         target.addEventListener('x', (event) => { log.push('first'); event.stopImmediatePropagation(); }, true);
         target.addEventListener('x', () => log.push('capture'), true);
         target.addEventListener('x', () => log.push('other'));
         const event = new Event('x');
         target.dispatchEvent(event);
         target.dispatchEvent(event);
         return log.join(' ');",
    )
    .await;

    assert_eq!(text, "first first");
}

#[tokio::test]
async fn a_listener_cancels_only_a_cancelable_event() {
    let text = run::<String>(
        "a_listener_cancels_only_a_cancelable_event",
        "const target = new EventTarget();
         target.addEventListener('x', (event) => event.preventDefault());
         const plain = new Event('x');
         const cancelable = new Event('x', { cancelable: true });
         return [target.dispatchEvent(plain), plain.defaultPrevented, target.dispatchEvent(cancelable),
           cancelable.defaultPrevented].join(' ');",
    )
    .await;

    assert_eq!(text, "true false false true");
}

#[tokio::test]
async fn a_passive_listener_cannot_cancel_and_a_later_call_can() {
    let text = run::<String>(
        "a_passive_listener_cannot_cancel_and_a_later_call_can",
        "const target = new EventTarget();
         target.addEventListener('x', (event) => event.preventDefault(), { passive: true });
         const event = new Event('x', { cancelable: true });
         const first = target.dispatchEvent(event);
         event.preventDefault();
         target.addEventListener('x', (event) => event.preventDefault());
         return [first, event.defaultPrevented, target.dispatchEvent(new Event('x', { cancelable: true }))].join(' ');",
    )
    .await;

    assert_eq!(text, "true true false");
}

#[tokio::test]
async fn an_event_in_a_dispatch_cannot_be_dispatched_again_and_another_event_can() {
    let text = run::<String>(
        "an_event_in_a_dispatch_cannot_be_dispatched_again_and_another_event_can",
        "const target = new EventTarget();
         const event = new Event('x');
         const log = [];
         target.addEventListener('x', () => {
           try { target.dispatchEvent(event); } catch (error) { log.push(`${error instanceof DOMException} ${error.name}`); }
           target.dispatchEvent(new Event('y'));
         });
         target.addEventListener('y', () => log.push('y'));
         target.dispatchEvent(event);
         return log.join(', ');",
    )
    .await;

    assert_eq!(text, "true InvalidStateError, y");
}

#[tokio::test]
async fn a_second_add_of_one_listener_with_one_capture_flag_does_nothing() {
    let calls = run::<i32>(
        "a_second_add_of_one_listener_with_one_capture_flag_does_nothing",
        "const target = new EventTarget();
         let calls = 0;
         const listener = () => { calls += 1; };
         target.addEventListener('x', listener);
         target.addEventListener('x', listener, { once: true });
         target.addEventListener('x', listener, true);
         target.dispatchEvent(new Event('x'));
         target.dispatchEvent(new Event('x'));
         return calls;",
    )
    .await;

    assert_eq!(calls, 4);
}

#[tokio::test]
async fn a_remove_needs_the_capture_flag_of_the_add() {
    let calls = run::<i32>(
        "a_remove_needs_the_capture_flag_of_the_add",
        "const target = new EventTarget();
         let calls = 0;
         const listener = () => { calls += 1; };
         const other = () => { calls += 10; };
         target.addEventListener('x', listener, true);
         target.addEventListener('x', other, { capture: true });
         target.removeEventListener('x', listener);
         target.dispatchEvent(new Event('x'));
         target.removeEventListener('x', listener, { capture: true });
         target.removeEventListener('x', other, true);
         target.dispatchEvent(new Event('x'));
         return calls;",
    )
    .await;

    assert_eq!(calls, 11);
}

#[tokio::test]
async fn a_once_listener_is_removed_before_its_call() {
    let calls = run::<i32>(
        "a_once_listener_is_removed_before_its_call",
        "const target = new EventTarget();
         let calls = 0;
         target.addEventListener('x', () => { calls += 1; target.dispatchEvent(new Event('x')); }, { once: true });
         target.dispatchEvent(new Event('x'));
         target.dispatchEvent(new Event('x'));
         return calls;",
    )
    .await;

    assert_eq!(calls, 1);
}

#[tokio::test]
async fn a_listener_that_a_listener_removes_does_not_run_and_an_added_one_waits_for_the_next_pass() {
    let text = run::<String>(
        "a_listener_that_a_listener_removes_does_not_run_and_an_added_one_waits_for_the_next_pass",
        "const target = new EventTarget();
         const log = [];
         const later = () => log.push('later');
         target.addEventListener('x', () => {
           log.push('capture');
           target.addEventListener('x', () => log.push('added in capture'));
         }, true);
         target.addEventListener('x', () => {
           log.push('other');
           target.removeEventListener('x', later);
           target.addEventListener('x', () => log.push('added in other'));
         });
         target.addEventListener('x', later);
         target.dispatchEvent(new Event('x'));
         return log.join(', ');",
    )
    .await;

    assert_eq!(text, "capture, other, added in capture");
}

#[tokio::test]
async fn a_listener_object_reads_its_handle_event_at_each_call() {
    let text = run::<String>(
        "a_listener_object_reads_its_handle_event_at_each_call",
        "const target = new EventTarget();
         const log = [];
         const listener = { handleEvent(event) { log.push(`${this === listener} ${event.type}`); } };
         target.addEventListener('x', listener);
         target.dispatchEvent(new Event('x'));
         listener.handleEvent = () => log.push('replaced');
         target.dispatchEvent(new Event('x'));
         return log.join(', ');",
    )
    .await;

    assert_eq!(text, "true x, replaced");
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
async fn a_method_refuses_a_value_of_another_class() {
    let text = run::<String>(
        "a_method_refuses_a_value_of_another_class",
        &format!(
            "{NAMES}
             const fake = {{ aborted: false, reason: undefined }};
             const getter = (type, name) => Object.getOwnPropertyDescriptor(type.prototype, name).get;
             return names([
               () => EventTarget.prototype.addEventListener.call({{}}, 'x', null),
               () => new EventTarget().dispatchEvent({{ type: 'x' }}),
               () => new EventTarget().addEventListener('x', () => {{}}, {{ signal: fake }}),
               () => new EventTarget().addEventListener('x', 5),
               () => getter(Event, 'type').call({{}}),
               () => getter(AbortSignal, 'aborted').call(fake),
               () => getter(AbortController, 'signal').call({{}}),
               () => AbortSignal.any([fake]),
               () => AbortSignal.any(''),
               () => AbortSignal.any(5),
             ]);"
        ),
    )
    .await;

    assert_eq!(text, ["TypeError"; 10].join(" "));
}

#[tokio::test]
async fn a_missing_argument_throws_a_type_error() {
    let text = run::<String>(
        "a_missing_argument_throws_a_type_error",
        &format!(
            "{NAMES}
             const target = new EventTarget();
             return names([
               () => target.addEventListener('x'),
               () => target.removeEventListener('x'),
               () => target.dispatchEvent(),
               () => AbortSignal.any(),
               () => AbortSignal.timeout(),
               () => target.addEventListener('x', null),
             ]);"
        ),
    )
    .await;

    assert_eq!(text, "TypeError TypeError TypeError TypeError TypeError none");
}

#[tokio::test]
async fn an_aborted_signal_adds_no_listener_and_an_abort_removes_one() {
    let calls = run::<i32>(
        "an_aborted_signal_adds_no_listener_and_an_abort_removes_one",
        "const target = new EventTarget();
         let calls = 0;
         target.addEventListener('x', () => { calls += 1; }, { signal: AbortSignal.abort() });
         const controller = new AbortController();
         target.addEventListener('x', () => { calls += 10; }, { signal: controller.signal });
         target.dispatchEvent(new Event('x'));
         controller.abort();
         target.dispatchEvent(new Event('x'));
         return calls;",
    )
    .await;

    assert_eq!(calls, 10);
}

#[tokio::test]
async fn only_an_abort_of_the_signal_removes_a_listener() {
    let text = run::<String>(
        "only_an_abort_of_the_signal_removes_a_listener",
        "const target = new EventTarget();
         let calls = 0;
         const stopped = new AbortController();
         stopped.signal.addEventListener('abort', (event) => {
           event.stopImmediatePropagation();
           target.dispatchEvent(new Event('x'));
         });
         target.addEventListener('x', () => { calls += 1; }, { signal: stopped.signal });
         const faked = new AbortController();
         target.addEventListener('x', () => { calls += 10; }, { signal: faked.signal });
         faked.signal.dispatchEvent(new Event('abort'));
         stopped.abort();
         target.dispatchEvent(new Event('x'));
         return `${calls} ${faked.signal.aborted}`;",
    )
    .await;

    assert_eq!(text, "20 false");
}

#[tokio::test]
async fn a_signal_has_no_public_constructor() {
    let text = run::<String>(
        "a_signal_has_no_public_constructor",
        &format!(
            "{NAMES}
             class Mine extends AbortSignal {{}}
             return names([() => new AbortSignal(), () => new Mine()]);"
        ),
    )
    .await;

    assert_eq!(text, "TypeError TypeError");
}

#[tokio::test]
async fn a_controller_aborts_its_signal_once_with_the_first_reason() {
    let text = run::<String>(
        "a_controller_aborts_its_signal_once_with_the_first_reason",
        "const controller = new AbortController();
         const signal = controller.signal;
         const reason = { why: 1 };
         let calls = 0;
         signal.addEventListener('abort', () => { calls += 1; });
         const before = [signal.aborted, signal.reason];
         controller.abort(reason);
         controller.abort('second');
         return [controller.signal === signal, ...before, signal.aborted, signal.reason === reason, calls]
           .map(String).join(' ');",
    )
    .await;

    assert_eq!(text, "true false undefined true true 1");
}

#[tokio::test]
async fn an_abort_without_a_reason_gives_an_abort_error_and_null_stays_null() {
    let text = run::<String>(
        "an_abort_without_a_reason_gives_an_abort_error_and_null_stays_null",
        "const controller = new AbortController();
         controller.abort();
         const nulled = new AbortController();
         nulled.abort(null);
         const reason = controller.signal.reason;
         const reasons = [{}, undefined, null].map((value) => AbortSignal.abort(value));
         return [reason instanceof DOMException, reason.name, reason.code, nulled.signal.reason,
           reasons[0].aborted, reasons[0].reason instanceof Object, reasons[1].reason.name, reasons[2].reason]
           .map(String).join(' ');",
    )
    .await;

    assert_eq!(text, "true AbortError 20 null true true AbortError null");
}

#[tokio::test]
async fn an_abort_event_is_trusted_until_a_script_dispatches_it() {
    let text = run::<String>(
        "an_abort_event_is_trusted_until_a_script_dispatches_it",
        "const controller = new AbortController();
         let seen = [];
         let event;
         controller.signal.addEventListener('abort', (abort) => {
           event = abort;
           seen = [abort.type, abort.isTrusted, abort.bubbles, abort.cancelable, abort.target === controller.signal];
         });
         controller.abort();
         new EventTarget().dispatchEvent(event);
         return [...seen, event.isTrusted].join(' ');",
    )
    .await;

    assert_eq!(text, "abort true false false true false");
}

#[tokio::test]
async fn a_listener_added_after_the_abort_does_not_run() {
    let calls = run::<i32>(
        "a_listener_added_after_the_abort_does_not_run",
        "const signal = AbortSignal.abort();
         let calls = 0;
         signal.addEventListener('abort', () => { calls += 1; });
         signal.onabort = () => { calls += 1; };
         await new Promise((resolve) => setTimeout(resolve, 0));
         return calls;",
    )
    .await;

    assert_eq!(calls, 0);
}

#[tokio::test]
async fn throw_if_aborted_throws_the_reason_only_after_the_abort() {
    let same = run::<bool>(
        "throw_if_aborted_throws_the_reason_only_after_the_abort",
        "const controller = new AbortController();
         const reason = new Error('stop');
         controller.signal.throwIfAborted();
         controller.abort(reason);
         try { controller.signal.throwIfAborted(); } catch (error) { return error === reason; }
         return false;",
    )
    .await;

    assert!(same);
}

#[tokio::test]
async fn onabort_keeps_its_place_until_a_clear() {
    let text = run::<String>(
        "onabort_keeps_its_place_until_a_clear",
        "const log = [];
         const one = new AbortController();
         one.signal.onabort = () => log.push('old');
         one.signal.addEventListener('abort', () => log.push('listener'));
         one.signal.onabort = function (event) { log.push(`${this === one.signal} ${event.type}`); };
         one.abort();
         const two = new AbortController();
         two.signal.onabort = () => log.push('cleared');
         two.signal.addEventListener('abort', () => log.push('second'));
         two.signal.onabort = null;
         two.signal.onabort = () => log.push('third');
         two.abort();
         return log.join(', ');",
    )
    .await;

    assert_eq!(text, "true abort, listener, second, third");
}

#[tokio::test]
async fn onabort_keeps_an_object_and_clears_for_another_value() {
    let text = run::<String>(
        "onabort_keeps_an_object_and_clears_for_another_value",
        "const signal = new AbortController().signal;
         const handler = () => {};
         const object = {};
         signal.onabort = handler;
         const first = signal.onabort === handler;
         signal.onabort = object;
         const second = signal.onabort === object;
         signal.onabort = 5;
         return [first, second, signal.onabort].map(String).join(' ');",
    )
    .await;

    assert_eq!(text, "true true null");
}

#[tokio::test]
async fn any_takes_the_reason_of_the_first_aborted_input() {
    let text = run::<String>(
        "any_takes_the_reason_of_the_first_aborted_input",
        "const open = new AbortController();
         const signal = AbortSignal.any([open.signal, AbortSignal.abort('b'), AbortSignal.abort('c')]);
         const callable = Object.assign(() => {}, { *[Symbol.iterator]() { yield AbortSignal.abort('d'); } });
         return `${signal.aborted} ${signal.reason} ${AbortSignal.any(callable).reason}`;",
    )
    .await;

    assert_eq!(text, "true b d");
}

#[tokio::test]
async fn any_aborts_with_the_first_source_that_aborts() {
    let text = run::<String>(
        "any_aborts_with_the_first_source_that_aborts",
        "const a = new AbortController();
         const b = new AbortController();
         const signal = AbortSignal.any([a.signal, b.signal]);
         const log = [];
         signal.addEventListener('abort', () => log.push(signal.reason));
         b.abort('b');
         a.abort('a');
         return `${log.join(' ')} ${signal.reason}`;",
    )
    .await;

    assert_eq!(text, "b b");
}

#[tokio::test]
async fn a_dependent_signal_of_a_dependent_aborts_before_the_listeners_of_the_source_run() {
    let text = run::<String>(
        "a_dependent_signal_of_a_dependent_aborts_before_the_listeners_of_the_source_run",
        "const controller = new AbortController();
         const first = AbortSignal.any([controller.signal]);
         const nested = AbortSignal.any([first]);
         const log = [];
         controller.signal.addEventListener('abort', () => log.push(`source ${first.aborted} ${nested.aborted}`));
         first.addEventListener('abort', () => log.push('first'));
         nested.addEventListener('abort', () => log.push(`nested ${nested.reason}`));
         controller.abort('why');
         return log.join(', ');",
    )
    .await;

    assert_eq!(text, "source true true, first, nested why");
}

#[tokio::test]
async fn an_abort_in_an_abort_listener_keeps_the_first_reason_of_a_dependent() {
    let text = run::<String>(
        "an_abort_in_an_abort_listener_keeps_the_first_reason_of_a_dependent",
        "const a = new AbortController();
         const b = new AbortController();
         const signal = AbortSignal.any([a.signal, b.signal]);
         a.signal.addEventListener('abort', () => b.abort('b'));
         a.abort('a');
         return signal.reason;",
    )
    .await;

    assert_eq!(text, "a");
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
async fn timeout_aborts_with_a_timeout_error_after_its_delay() {
    let text = run::<String>(
        "timeout_aborts_with_a_timeout_error_after_its_delay",
        "const started = performance.now();
         const signal = AbortSignal.timeout(20);
         const zero = AbortSignal.timeout(0);
         const before = [signal.aborted, zero.aborted];
         await new Promise((resolve) => signal.addEventListener('abort', resolve));
         return [...before, performance.now() - started >= 20, signal.reason.name, signal.reason.code, zero.aborted]
           .join(' ');",
    )
    .await;

    assert_eq!(text, "false false true TimeoutError 23 true");
}

#[tokio::test]
async fn timeout_drops_the_fraction_and_refuses_a_value_out_of_range() {
    let text = run::<String>(
        "timeout_drops_the_fraction_and_refuses_a_value_out_of_range",
        &format!(
            "{NAMES}
             const timeout = (value) => () => AbortSignal.timeout(value);
             return names([-1, Number.NaN, Number.POSITIVE_INFINITY, 2 ** 53, Symbol(), 1n, undefined, 1.9, -0.9, '5']
               .map(timeout));"
        ),
    )
    .await;

    assert_eq!(
        text,
        "TypeError TypeError TypeError TypeError TypeError TypeError TypeError none none none"
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
async fn is_trusted_is_an_own_property_that_a_script_cannot_redefine() {
    let text = run::<String>(
        "is_trusted_is_an_own_property_that_a_script_cannot_redefine",
        &format!(
            "{NAMES}
             const event = new Event('x');
             const descriptor = Object.getOwnPropertyDescriptor(event, 'isTrusted');
             return [
               descriptor.configurable,
               names([() => Object.defineProperty(event, 'isTrusted', {{ value: true }})]),
               event.isTrusted,
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "false TypeError false");
}

#[tokio::test]
async fn an_onabort_handler_that_returns_false_cancels_a_cancelable_event() {
    let text = run::<String>(
        "an_onabort_handler_that_returns_false_cancels_a_cancelable_event",
        "const signal = new AbortController().signal;
         signal.onabort = () => false;
         const event = new Event('abort', { cancelable: true });
         return `${signal.dispatchEvent(event)} ${event.defaultPrevented}`;",
    )
    .await;

    assert_eq!(text, "false true");
}

#[tokio::test]
async fn any_checks_each_value_before_it_asks_for_the_next() {
    let text = run::<String>(
        "any_checks_each_value_before_it_asks_for_the_next",
        "function* values() { yield {}; throw new Error('late'); }
         try { AbortSignal.any(values()); } catch (error) { return error.name; }
         return 'none';",
    )
    .await;

    assert_eq!(text, "TypeError");
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

#[tokio::test]
async fn any_takes_a_truthy_done_and_refuses_an_iterator_result_that_is_no_object() {
    let text = run::<String>(
        "any_takes_a_truthy_done_and_refuses_an_iterator_result_that_is_no_object",
        &format!(
            "{NAMES}
             const iterable = (results) => ({{ [Symbol.iterator]: () => ({{ next: () => results.shift() }}) }});
             const signal = AbortSignal.any(iterable([{{ done: 1 }}]));
             return [signal.aborted, names([() => AbortSignal.any(iterable([5]))])].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "false TypeError");
}

#[tokio::test]
async fn the_members_of_a_web_class_are_enumerable_on_its_prototype() {
    let text = run::<String>(
        "the_members_of_a_web_class_are_enumerable_on_its_prototype",
        "const members = [];
         for (const key in new AbortController().signal) members.push(key);
         return ['aborted', 'reason', 'throwIfAborted', 'addEventListener'].every((key) => members.includes(key))
           + ' ' + members.includes('constructor');",
    )
    .await;

    assert_eq!(text, "true false");
}
