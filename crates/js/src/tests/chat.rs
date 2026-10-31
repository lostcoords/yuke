//! The blocks of `yuke:chat` without a pane: the change listeners.

use std::sync::Arc;

use super::{evaluate, folder, next_fault, options};
use crate::{Options, Processes, Runtime};

#[tokio::test]
async fn a_throwing_change_listener_is_removed_with_one_fault_and_the_others_still_run() {
    let place = folder("chat_listeners");
    let (runtime, mut reports) = Runtime::start(Options {
        internal_imports: true,
        ..options(&place, Arc::new(Processes::new(place.join("processes"))))
    })
    .await
    .unwrap();

    let seen = evaluate::<String>(
        &runtime,
        "const { callEach } = await import('yuke:internal/chat/listeners');
         let ran = 0;
         const broken = () => { throw new Error('the listener broke'); };
         let added = 0;
         const listeners = new Set([broken, () => { ran += 1; }]);
         // A listener that adds a listener on each call: the new one waits for the next change.
         listeners.add(() => { listeners.add(() => { added += 1; }); });
         // A listener that removes a later one: the removed one does not run.
         let removedRan = 0;
         const removed = () => { removedRan += 1; };
         listeners.add(() => listeners.delete(removed));
         listeners.add(removed);
         callEach(listeners);
         callEach(listeners);
         return JSON.stringify([ran, added, removedRan, listeners.has(broken)]);",
    )
    .await
    .unwrap();

    assert_eq!(seen, "[2,1,0,false]");
    assert_eq!(next_fault(&mut reports).await.message, "the listener broke");
    assert!(reports.try_recv().is_err(), "a second fault came");
}
