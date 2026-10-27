//! The notices of the terminal interface: a fault of a listener reaches the reports of the runtime.

use rquickjs::{Ctx, Module, Object};

use super::{evaluate, folder, next_fault, start};
use crate::error::caught;

#[tokio::test]
async fn a_throwing_notice_listener_is_removed_and_reported_and_the_next_listener_runs() {
    let folder = folder("a_throwing_notice_listener_is_reported");
    let (runtime, mut reports) = start(&folder).await;
    runtime
        .caller
        .run(async move |ctx: Ctx<'_>, _registry| {
            let promise = caught(&ctx, Module::import(&ctx, "yuke:internal/tui/notices"))?;
            let namespace = caught(&ctx, promise.into_future::<Object<'_>>().await)?;
            let notices = caught(&ctx, namespace.get::<_, rquickjs::Value<'_>>("Notices"))?;
            caught(&ctx, ctx.globals().set("Notices", notices))
        })
        .await
        .unwrap();
    let seen = evaluate::<String>(
        &runtime,
        "const notices = new Notices();
         const seen = [];
         let calls = 0;
         notices.on(() => { calls += 1; throw new Error('a broken listener'); });
         notices.on((notice) => seen.push(notice.text));
         notices.add('info', 'notes', 'hello');
         notices.add('error', 'host:yuke', 'the fault of the listener');
         return `${seen.join(' ')} ${calls}`;",
    )
    .await
    .unwrap();
    // The broken listener is gone after its first throw, so its fault cannot feed it again.
    assert_eq!(seen, "hello the fault of the listener 1");
    let fault = next_fault(&mut reports).await;
    assert!(fault.message.contains("a broken listener"), "{fault:?}");
}
