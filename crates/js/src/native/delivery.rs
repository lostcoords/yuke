//! One ordered queue for view events, facts, and host replies of an engine.

use std::any::Any;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::{Rc, Weak};

use rquickjs::{Ctx, Function, IntoJs, Object, Promise};
use tokio::sync::mpsc;
use tokio::task::{AbortHandle, JoinError};

use crate::error::{Error, ErrorClass, Report, caught, throw};
use crate::sessions::{Fact, ViewEvent};
use crate::tools::Json;

/// The dispatcher yields after this many records, so other local tasks can run.
const BATCH: usize = 256;

/// Producers send only Rust data. They can hold host locks when they send events.
pub(super) enum Delivery {
    View(u32, Box<ViewEvent>),
    Fact(u32, Fact),
    Reply(u64, Box<dyn Any>),
}

type Reply<'js> = Box<dyn FnOnce(&Ctx<'js>, Box<dyn Any>) -> rquickjs::Result<()> + 'js>;

#[derive(Default)]
struct Routes<'js> {
    views: Option<Function<'js>>,
    facts: Option<Function<'js>>,
    replies: HashMap<u64, Reply<'js>>,
    last_key: u64,
}

/// `Queue` sends Rust data to the engine dispatcher. A sink holds only a clone of `sender`.
#[derive(Clone)]
pub(crate) struct Queue<'js> {
    pub(super) sender: mpsc::UnboundedSender<Delivery>,
    // Listeners can reach native functions, so the dispatcher alone owns the routes.
    routes: Weak<RefCell<Routes<'js>>>,
}

#[expect(unsafe_code, reason = "context user data needs the lifetime of the queue routes")]
// SAFETY: the routes and their callbacks use only the context lifetime. The weak reference cannot extend it.
unsafe impl<'js> rquickjs::JsLifetime<'js> for Queue<'js> {
    type Changed<'to> = Queue<'to>;
}

impl<'js> Queue<'js> {
    /// Get the queue of this engine.
    pub(crate) fn of(ctx: &Ctx<'js>) -> Self {
        ctx.userdata::<Self>()
            .unwrap_or_else(|| unreachable!("the engine installs its queue before calls start"))
            .clone()
    }

    pub(super) fn new(
        ctx: &Ctx<'js>,
        object: &Object<'js>,
        faults: mpsc::UnboundedSender<Report>,
    ) -> rquickjs::Result<Self> {
        let (sender, receiver) = mpsc::unbounded_channel();
        let routes = Rc::new(RefCell::new(Routes::default()));
        for (name, views) in [("sessionsListen", true), ("factsListen", false)] {
            let routes = Rc::downgrade(&routes);
            object.set(
                name,
                Function::new(ctx.clone(), move |ctx: Ctx<'js>, deliver: Function<'js>| {
                    let routes = routes
                        .upgrade()
                        .unwrap_or_else(|| unreachable!("the dispatcher lives while natives run"));
                    let mut routes = routes.borrow_mut();
                    let route = if views { &mut routes.views } else { &mut routes.facts };
                    if route.is_some() {
                        return Err(throw(
                            &ctx,
                            ErrorClass::TypeError,
                            "the event route already has a listener",
                        ));
                    }
                    *route = Some(deliver);
                    Ok(())
                })?,
            )?;
        }
        let queue = Self {
            sender,
            routes: Rc::downgrade(&routes),
        };
        ctx.spawn(dispatch(ctx.clone(), receiver, routes, faults));
        Ok(queue)
    }

    /// Run the host future in a local task. Resolve its promise in queue order, after each record queued before the reply.
    pub(crate) fn request<T, R>(
        &self,
        ctx: &Ctx<'js>,
        run: impl Future<Output = T> + 'static,
        finish: impl FnOnce(&Ctx<'js>, Result<T, JoinError>) -> rquickjs::Result<R> + 'js,
    ) -> rquickjs::Result<(Promise<'js>, AbortHandle)>
    where
        T: 'static,
        R: IntoJs<'js>,
    {
        let (promise, resolve, reject) = Promise::new(ctx)?;
        let key = {
            let routes = self
                .routes
                .upgrade()
                .unwrap_or_else(|| unreachable!("the dispatcher lives while natives run"));
            let mut routes = routes.borrow_mut();
            routes.last_key += 1;
            let key = routes.last_key;
            routes.replies.insert(
                key,
                Box::new(move |ctx, result| {
                    // The request and its route share `T`. The queue erases `T` so one queue can carry every reply type.
                    let result = *result
                        .downcast::<Result<T, JoinError>>()
                        .unwrap_or_else(|_| unreachable!("the reply type matches its request"));
                    match finish(ctx, result).and_then(|value| value.into_js(ctx)) {
                        Ok(value) => resolve.call((value,)),
                        Err(error) => {
                            let value = if error.is_exception() {
                                ctx.catch()
                            } else {
                                throw(ctx, ErrorClass::Error, &error.to_string());
                                ctx.catch()
                            };
                            reject.call((value,))
                        }
                    }
                }),
            );
            key
        };
        let task = tokio::task::spawn_local(run);
        let abort = task.abort_handle();
        let sender = self.sender.clone();
        ctx.spawn(async move {
            let result = task.await;
            if sender.send(Delivery::Reply(key, Box::new(result))).is_err() {
                // The engine stopped, so it takes no more replies.
            }
        });
        Ok((promise, abort))
    }
}

async fn dispatch<'js>(
    ctx: Ctx<'js>,
    mut received: mpsc::UnboundedReceiver<Delivery>,
    routes: Rc<RefCell<Routes<'js>>>,
    faults: mpsc::UnboundedSender<Report>,
) {
    while let Some(first) = received.recv().await {
        for delivery in std::iter::once(first)
            .chain(std::iter::from_fn(|| received.try_recv().ok()))
            .take(BATCH)
        {
            let result = match delivery {
                Delivery::View(key, event) => {
                    let deliver = routes.borrow().views.clone();
                    deliver.map_or(Ok(()), |deliver| deliver.call((key, Json(event))))
                }
                Delivery::Fact(key, fact) => {
                    let deliver = routes.borrow().facts.clone();
                    deliver.map_or(Ok(()), |deliver| deliver.call((key, Json(fact))))
                }
                Delivery::Reply(key, result) => {
                    let reply = routes
                        .borrow_mut()
                        .replies
                        .remove(&key)
                        .unwrap_or_else(|| unreachable!("each reply has a route"));
                    reply(&ctx, result)
                }
            };
            if let Err(Error::Script(error)) = caught(&ctx, result)
                && faults.send(Report::Fault(error)).is_err()
            {
                // The owner dropped the receiver, so it ignores faults.
            }
        }
        tokio::task::yield_now().await;
    }
}
