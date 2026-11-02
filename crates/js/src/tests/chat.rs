//! The blocks of `yuke:chat` without a pane: the change listeners.

use std::rc::Rc;

use super::{evaluate, folder, options};
use crate::{Options, Processes, Runtime};

#[tokio::test(flavor = "local")]
async fn change_listeners_defer_additions_and_skip_removed_listeners() {
    let place = folder("chat_listeners");
    let (runtime, _reports) = Runtime::start(Options {
        internal_imports: true,
        ..options(&place, Rc::new(Processes::new(place.join("processes"))))
    })
    .await
    .unwrap();

    let seen = evaluate::<String>(
        &runtime,
        "const { callEach } = await import('yuke:internal/chat/listeners');
         let ran = 0;
         let added = 0;
         const listeners = new Set([() => { ran += 1; }]);
         // A listener that adds a listener on each call: the new one waits for the next change.
         listeners.add(() => { listeners.add(() => { added += 1; }); });
         // A listener that removes a later one: the removed one does not run.
         let removedRan = 0;
         const removed = () => { removedRan += 1; };
         listeners.add(() => listeners.delete(removed));
         listeners.add(removed);
         callEach(listeners);
         callEach(listeners);
         return JSON.stringify([ran, added, removedRan]);",
    )
    .await
    .unwrap();

    assert_eq!(seen, "[2,1,0]");
}
