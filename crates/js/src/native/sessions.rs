//! The session functions of the native module: the requests of `ctx.get("sessions")` and `ctx.get("catalog")`, and
//! the feed that delivers the events of the views to JavaScript.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::rc::Rc;
use std::sync::{Arc, Mutex, PoisonError};

use rquickjs::{Ctx, Function, Object, Promise, TypedArray};
use serde::de::DeserializeOwned;
use serde::{Serialize, Serializer};
use tokio::runtime::Handle;
use tokio::sync::{Notify, mpsc, oneshot};
use yuke_ai::{Block, MAX_MEDIA_BYTES};
use yuke_engine::chain_text;
use yuke_protocol::{
    EventNumber, Input, InputId, InputKind, InputSource, InteractionId, InteractionResponse, ListSessionsParams,
    SessionId, SessionSettings,
};

use crate::error::{Error, ErrorClass, Report, caught, throw};
use crate::sessions::{Sessions, SessionsError, ViewEvent};
use crate::tools::Json;

/// The most events of one delivery. The feed yields between deliveries, so keys and frames come between them.
const BATCH: usize = 256;

/// The events of the views of one runtime, in order, each with the key of its view.
#[derive(Default)]
struct Feed {
    events: Mutex<VecDeque<(u32, ViewEvent)>>,
    arrived: Notify,
    /// The flushes that wait until the feed delivered each event before them.
    flushes: Mutex<Vec<oneshot::Sender<()>>>,
}

impl Feed {
    fn push(&self, key: u32, event: ViewEvent) {
        self.events
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push_back((key, event));
        self.arrived.notify_one();
    }

    /// The next events, at most [`BATCH`]. It waits while the feed is empty and no flush waits.
    async fn next(&self) -> Vec<(u32, ViewEvent)> {
        loop {
            {
                let mut events = self.events.lock().unwrap_or_else(PoisonError::into_inner);
                if !events.is_empty() {
                    let count = events.len().min(BATCH);
                    return events.drain(..count).collect();
                }
            }
            if !self.flushes.lock().unwrap_or_else(PoisonError::into_inner).is_empty() {
                return Vec::new();
            }
            self.arrived.notified().await;
        }
    }

    /// A wait for the delivery of each event that the feed holds now.
    fn flush(&self) -> oneshot::Receiver<()> {
        let (sender, receiver) = oneshot::channel();
        self.flushes.lock().unwrap_or_else(PoisonError::into_inner).push(sender);
        self.arrived.notify_one();
        receiver
    }

    /// End each flush when the feed is empty: the delivery has given each event before them.
    fn end_flushes(&self) {
        if !self.events.lock().unwrap_or_else(PoisonError::into_inner).is_empty() {
            return;
        }
        for flush in self.flushes.lock().unwrap_or_else(PoisonError::into_inner).drain(..) {
            if flush.send(()).is_err() {
                // The caller stopped waiting.
            }
        }
    }
}

/// The JSON of an event for JavaScript: `{ snapshot }`, `{ update }`, or `"closed"`.
impl Serialize for ViewEvent {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Snapshot(snapshot) => serializer.serialize_newtype_variant("ViewEvent", 0, "snapshot", snapshot),
            Self::Update(update) => serializer.serialize_newtype_variant("ViewEvent", 1, "update", update),
            Self::Closed => serializer.serialize_unit_variant("ViewEvent", 2, "closed"),
        }
    }
}

/// Add the session functions to `object`, the export object of the native module. Each request runs on the runtime of
/// the consumer, so a request that JavaScript stops awaiting still ends.
pub(super) fn add<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    sessions: &Arc<dyn Sessions>,
    consumer: &Handle,
    faults: mpsc::UnboundedSender<Report>,
) -> rquickjs::Result<()> {
    let feed = Arc::new(Feed::default());
    // The hold and the view of each open handle, by its key. The drop of an entry ends both.
    let held: Rc<RefCell<HashMap<u32, Box<dyn Send>>>> = Rc::default();

    let flush_feed = Arc::clone(&feed);
    object.set(
        "sessionsFlush",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>| -> rquickjs::Result<Promise<'js>> {
            let flushed = flush_feed.flush();
            let error_ctx = ctx.clone();
            Promise::wrap_future(&ctx, async move {
                flushed
                    .await
                    .map_err(|_| throw(&error_ctx, ErrorClass::Error, "the feed of the sessions has ended"))
            })
        })?,
    )?;
    let listen_feed = Arc::clone(&feed);
    object.set(
        "sessionsListen",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, deliver: Function<'js>| {
            ctx.spawn(deliver_events(
                ctx.clone(),
                deliver,
                Arc::clone(&listen_feed),
                faults.clone(),
            ));
        })?,
    )?;

    let (open_sessions, open_consumer, open_held) = (Arc::clone(sessions), consumer.clone(), Rc::clone(&held));
    object.set(
        "sessionsOpen",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, arguments: Json<(u32, SessionId, usize)>| -> rquickjs::Result<Promise<'js>> {
                let (key, id, tail) = arguments.0;
                let (sessions, feed, held) = (Arc::clone(&open_sessions), Arc::clone(&feed), Rc::clone(&open_held));
                let sink = Arc::new(move |event| feed.push(key, event));
                let task = open_consumer.spawn(async move { sessions.open(id, tail, sink).await });
                let error_ctx = ctx.clone();
                Promise::wrap_future(&ctx, async move {
                    let guard = joined(&error_ctx, task.await)?;
                    held.borrow_mut().insert(key, guard);
                    rquickjs::Result::Ok(())
                })
            },
        )?,
    )?;
    object.set(
        "sessionsRelease",
        Function::new(ctx.clone(), move |key: u32| {
            // The drop ends the hold and the view.
            drop(held.borrow_mut().remove(&key));
        })?,
    )?;

    add_requests(object, sessions, consumer)?;
    add_calls(ctx, object, sessions)
}

/// Add the asynchronous requests, which run on the runtime of the consumer.
fn add_requests(object: &Object<'_>, sessions: &Arc<dyn Sessions>, consumer: &Handle) -> rquickjs::Result<()> {
    add_put_blob(object, sessions, consumer)?;
    let request = Requests {
        sessions: Arc::clone(sessions),
        consumer: consumer.clone(),
    };
    request.add(
        object,
        "sessionsCreate",
        |sessions, settings: SessionSettings| async move { sessions.create(settings).await },
    )?;
    request.add(
        object,
        "sessionsFork",
        |sessions, (id, through): (SessionId, Option<EventNumber>)| async move { sessions.fork(id, through).await },
    )?;
    request.add(
        object,
        "sessionsList",
        |sessions, params: ListSessionsParams| async move { sessions.list(params).await },
    )?;
    request.add(object, "sessionsGet", |sessions, id: SessionId| async move {
        sessions.get(id).await
    })?;
    request.add(object, "sessionsRemove", |sessions, id: SessionId| async move {
        sessions.remove(id).await
    })?;
    request.add(
        object,
        "sessionsEvents",
        |sessions, (id, before, limit): (SessionId, Option<EventNumber>, usize)| async move {
            sessions.events_before(id, before, limit).await
        },
    )?;
    request.add(
        object,
        "sessionInput",
        |sessions, (id, content, model_content): (SessionId, Vec<Block>, Option<Vec<Block>>)| async move {
            let input = Input::new(InputSource::User, InputKind::Message, content)?;
            let input = match model_content {
                Some(model_content) => input.with_model_content(model_content)?,
                None => input,
            };
            sessions.input(id, input).await
        },
    )?;
    request.add(
        object,
        "sessionNotify",
        |sessions, (id, plugin, display, text): (SessionId, String, String, String)| async move {
            sessions.input(id, Input::notification(&plugin, &display, &text)).await
        },
    )?;
    request.add(object, "sessionIdle", |sessions, id: SessionId| async move {
        sessions.idle(id).await
    })?;
    request.add(
        object,
        "sessionSetSettings",
        |sessions, (id, settings): (SessionId, SessionSettings)| async move { sessions.set_settings(id, settings).await },
    )?;
    request.add(
        object,
        "sessionRemoveInput",
        |sessions, (id, input_id): (SessionId, InputId)| async move { sessions.remove_input(id, input_id).await },
    )?;
    request.add(
        object,
        "sessionStopJob",
        |sessions, (id, job_id): (SessionId, String)| async move { sessions.stop_job(id, job_id).await },
    )?;
    request.add(
        object,
        "sessionClose",
        |sessions, (id, stop_jobs): (SessionId, bool)| async move { sessions.close(id, stop_jobs).await },
    )?;
    request.add(object, "catalogList", |sessions, all: bool| async move {
        sessions.catalog(all).await
    })?;

    Ok(())
}

/// Add the requests that answer at once.
fn add_calls<'js>(ctx: &Ctx<'js>, object: &Object<'js>, sessions: &Arc<dyn Sessions>) -> rquickjs::Result<()> {
    let calls = Arc::clone(sessions);
    object.set(
        "sessionCancel",
        Function::new(ctx.clone(), move |id: Json<SessionId>| calls.cancel(id.0))?,
    )?;
    let calls = Arc::clone(sessions);
    object.set(
        "sessionRespond",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>,
                  arguments: Json<(SessionId, InteractionId, InteractionResponse)>|
                  -> rquickjs::Result<()> {
                let (id, interaction_id, response) = arguments.0;
                calls
                    .respond(id, interaction_id, response)
                    .map_err(|error| failure(&ctx, &error))
            },
        )?,
    )?;
    let calls = Arc::clone(sessions);
    object.set(
        "sessionJobs",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, id: Json<SessionId>| {
            calls.jobs(id.0).map(Json).map_err(|error| failure(&ctx, &error))
        })?,
    )?;
    let calls = Arc::clone(sessions);
    object.set(
        "sessionMcpServers",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, id: Json<SessionId>| {
            calls.mcp_servers(id.0).map(Json).map_err(|error| failure(&ctx, &error))
        })?,
    )?;
    Ok(())
}

/// Call `deliver` with each batch of the feed, as `[key, event]` pairs, until the runtime stops. A throw of `deliver` is
/// a fault, and the next batch still comes.
async fn deliver_events<'js>(
    ctx: Ctx<'js>,
    deliver: Function<'js>,
    feed: Arc<Feed>,
    faults: mpsc::UnboundedSender<Report>,
) {
    loop {
        let batch = feed.next().await;
        if !batch.is_empty() {
            let result = deliver.call::<_, ()>((Json(batch),));
            if let Err(Error::Script(error)) = caught(&ctx, result)
                && faults.send(Report::Fault(error)).is_err()
            {
                // The owner dropped the receiver, so it ignores faults.
            }
        }
        feed.end_flushes();
        tokio::task::yield_now().await;
    }
}

/// Add `sessionPutBlob(id, bytes)`. The bytes come as a `Uint8Array`, not as JSON, so the call copies them before the
/// task runs. Bytes over the limit of an attachment throw before the store sees them.
fn add_put_blob<'js>(object: &Object<'js>, sessions: &Arc<dyn Sessions>, consumer: &Handle) -> rquickjs::Result<()> {
    let (sessions, consumer) = (Arc::clone(sessions), consumer.clone());
    object.set(
        "sessionPutBlob",
        Function::new(
            object.ctx().clone(),
            move |ctx: Ctx<'js>, id: Json<SessionId>, bytes: TypedArray<'js, u8>| -> rquickjs::Result<Promise<'js>> {
                let bytes = crate::bytes::copy(&bytes)?;
                if bytes.len() as u64 > MAX_MEDIA_BYTES {
                    let text = format!("the blob is larger than the limit of {MAX_MEDIA_BYTES} bytes");
                    return Err(throw(&ctx, ErrorClass::Error, &text));
                }
                let sessions = Arc::clone(&sessions);
                let task = consumer.spawn(async move { sessions.put_blob(id.0, bytes).await });
                let error_ctx = ctx.clone();
                Promise::wrap_future(&ctx, async move { joined(&error_ctx, task.await).map(Json) })
            },
        )?,
    )
}

/// The answer of a request task for JavaScript: its value, or a throw with the text of its failure.
fn joined<T>(ctx: &Ctx<'_>, joined: Result<Result<T, SessionsError>, tokio::task::JoinError>) -> rquickjs::Result<T> {
    match joined {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(failure(ctx, &error)),
        Err(error) => Err(throw(ctx, ErrorClass::Error, &error.to_string())),
    }
}

/// The throw of a failed request.
fn failure(ctx: &Ctx<'_>, error: &SessionsError) -> rquickjs::Error {
    throw(ctx, ErrorClass::Error, &chain_text(&**error))
}

/// Adds the asynchronous requests: each one takes its arguments as one JSON value, runs on the runtime of the consumer,
/// and answers a promise of its JSON.
struct Requests {
    sessions: Arc<dyn Sessions>,
    consumer: Handle,
}

impl Requests {
    fn add<'js, A, T, F>(
        &self,
        object: &Object<'js>,
        name: &str,
        run: impl Fn(Arc<dyn Sessions>, A) -> F + 'js,
    ) -> rquickjs::Result<()>
    where
        A: DeserializeOwned + 'js,
        T: Serialize + Send + 'static,
        F: Future<Output = Result<T, SessionsError>> + Send + 'static,
    {
        let (sessions, consumer) = (Arc::clone(&self.sessions), self.consumer.clone());
        object.set(
            name,
            Function::new(
                object.ctx().clone(),
                move |ctx: Ctx<'js>, arguments: Json<A>| -> rquickjs::Result<Promise<'js>> {
                    let task = consumer.spawn(run(Arc::clone(&sessions), arguments.0));
                    let error_ctx = ctx.clone();
                    Promise::wrap_future(&ctx, async move { joined(&error_ctx, task.await).map(Json) })
                },
            )?,
        )
    }
}
