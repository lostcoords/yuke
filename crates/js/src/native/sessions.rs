//! The session functions of the native module: the requests of `ctx.get("sessions")`, `ctx.get("catalog")`, and
//! `ctx.get("plugins")`. The queue delivers host view events and host facts and resolves the asynchronous request
//! promises. Synchronous natives read the current host state directly. Facts that start in JavaScript go to listeners
//! at once.

use std::any::Any;
use std::cell::RefCell;
use std::collections::HashMap;
use std::future::Future;
use std::rc::Rc;

use rquickjs::{Ctx, Function, IntoJs, Object, Promise, TypedArray};
use serde::de::DeserializeOwned;
use serde::{Serialize, Serializer};
use yuke_ai::Block;
use yuke_engine::chain_text;
use yuke_protocol::{
    ApplyPluginsParams, CheckPluginsParams, EventNumber, Input, InputId, InputKind, InputSource, InteractionId,
    InteractionResponse, ListSessionsParams, SessionId, SessionSettings, SessionTitle, SyncPluginsParams,
};

use super::delivery::{Delivery, Queue};
use super::{Cancelled, Operation};
use crate::error::{ErrorClass, throw};
use crate::sessions::{FactSink, Sessions, SessionsError, ViewEvent};

use crate::tools::Json;

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

/// Add the session functions to `object`, the export object of the native module. Each request runs as a local task,
/// so a request that JavaScript stops awaiting still ends.
pub(super) fn add<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    sessions: &Rc<dyn Sessions>,
    queue: &Queue<'js>,
) -> rquickjs::Result<()> {
    // The hold and the view of each open handle, by its key. The drop of an entry ends both.
    let held: Rc<RefCell<HashMap<u32, Box<dyn Any>>>> = Rc::default();

    add_facts(ctx, object, sessions, queue)?;
    let open_queue = queue.clone();

    let (open_sessions, open_held) = (Rc::clone(sessions), Rc::clone(&held));
    object.set(
        "sessionsOpen",
        Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, arguments: Json<(u32, SessionId, usize)>| -> rquickjs::Result<Promise<'js>> {
                let (key, id, tail) = arguments.0;
                let (sessions, held) = (Rc::clone(&open_sessions), Rc::clone(&open_held));
                let sender = open_queue.sender.clone();
                let sink = Rc::new(move |event| {
                    if sender.send(Delivery::View(key, Box::new(event))).is_err() {
                        // The engine stopped, so it takes no more events.
                    }
                });
                let (promise, _abort) = open_queue.request(
                    &ctx,
                    async move { sessions.open(id, tail, sink).await },
                    move |ctx, result| {
                        let guard = joined(ctx, result)?;
                        held.borrow_mut().insert(key, guard);
                        Ok(())
                    },
                )?;
                Ok(promise)
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

    add_requests(object, sessions, queue)?;
    add_calls(ctx, object, sessions)
}

/// Add `factsWatch(key)` and `factsRelease()` for the facts of `ctx.on`. One watch runs at a time. A new watch ends
/// the old one. The key of each fact names the watch that sent it.
fn add_facts<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    sessions: &Rc<dyn Sessions>,
    queue: &Queue<'js>,
) -> rquickjs::Result<()> {
    let sender = queue.sender.clone();
    let watch: Rc<RefCell<Option<Box<dyn Any>>>> = Rc::default();
    let (sessions, started) = (Rc::clone(sessions), Rc::clone(&watch));
    object.set(
        "factsWatch",
        Function::new(ctx.clone(), move |key: u32| {
            let sender = sender.clone();
            let sink: FactSink = Rc::new(move |fact| {
                if sender.send(Delivery::Fact(key, fact)).is_err() {
                    // The engine stopped, so it takes no more facts.
                }
            });
            // The old watch ends before the new one starts, so no fact of the old one follows the replay.
            drop(started.borrow_mut().take());
            *started.borrow_mut() = Some(sessions.watch_facts(sink));
        })?,
    )?;
    object.set(
        "factsRelease",
        Function::new(ctx.clone(), move || drop(watch.borrow_mut().take()))?,
    )
}

/// Add the asynchronous requests, which run as local tasks.
fn add_requests<'js>(object: &Object<'js>, sessions: &Rc<dyn Sessions>, queue: &Queue<'js>) -> rquickjs::Result<()> {
    add_put_blob(object, sessions, queue)?;
    let request = Requests {
        sessions: Rc::clone(sessions),
        queue: queue.clone(),
    };
    request.add(
        object,
        "sessionsCreate",
        |sessions, (settings, parent): (SessionSettings, Option<SessionId>)| async move {
            sessions.create(settings, parent).await
        },
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
        "sessionsRename",
        |sessions, (id, title): (SessionId, SessionTitle)| async move { sessions.rename(id, title).await },
    )?;
    request.add(
        object,
        "sessionRemoveInput",
        |sessions, (id, input_id): (SessionId, InputId)| async move { sessions.remove_input(id, input_id).await },
    )?;
    request.add(
        object,
        "sessionStopJob",
        |sessions, (id, job_id): (SessionId, String)| async move { sessions.stop_job(id, &job_id).await },
    )?;
    request.add(object, "sessionClose", |sessions, id: SessionId| async move {
        sessions.close(id).await
    })?;
    request.add(object, "catalogList", |sessions, all: bool| async move {
        sessions.catalog(all).await
    })?;
    add_plugin_requests(&request, object)
}

/// Add the requests of `ctx.get("plugins")`. A sync, a check, and an add fetch, so each one answers an operation.
fn add_plugin_requests<'js>(request: &Requests<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    request.add(object, "pluginsList", |sessions, (): ()| async move {
        sessions.list_plugins().await
    })?;
    request.add_operation(
        object,
        "pluginsSync",
        |sessions, params: SyncPluginsParams| async move { sessions.sync_plugins(params).await },
    )?;
    request.add_operation(
        object,
        "pluginsCheck",
        |sessions, params: CheckPluginsParams| async move { sessions.check_plugins(params).await },
    )?;
    request.add(
        object,
        "pluginsApply",
        |sessions, params: ApplyPluginsParams| async move { sessions.apply_plugins(params).await },
    )?;
    request.add_operation(
        object,
        "pluginsAdd",
        |sessions, params: yuke_protocol::AddPluginParams| async move { sessions.add_plugin(params).await },
    )?;
    request.add(
        object,
        "pluginsRemove",
        |sessions, params: yuke_protocol::RemovePluginParams| async move { sessions.remove_plugin(params).await },
    )?;

    Ok(())
}

/// Add the requests that answer at once.
fn add_calls<'js>(ctx: &Ctx<'js>, object: &Object<'js>, sessions: &Rc<dyn Sessions>) -> rquickjs::Result<()> {
    let calls = Rc::clone(sessions);
    object.set(
        "sessionCancel",
        Function::new(ctx.clone(), move |id: Json<SessionId>| calls.cancel(id.0))?,
    )?;
    let calls = Rc::clone(sessions);
    object.set(
        "sessionBackground",
        Function::new(ctx.clone(), move |id: Json<SessionId>| calls.background(id.0))?,
    )?;
    let calls = Rc::clone(sessions);
    object.set(
        "sessionHasMovable",
        Function::new(ctx.clone(), move |id: Json<SessionId>| calls.has_movable(id.0))?,
    )?;
    let calls = Rc::clone(sessions);
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
    let calls = Rc::clone(sessions);
    object.set(
        "sessionJobs",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, id: Json<SessionId>| {
            calls.jobs(id.0).map(Json).map_err(|error| failure(&ctx, &error))
        })?,
    )?;
    let calls = Rc::clone(sessions);
    object.set(
        "sessionMcpServers",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, id: Json<SessionId>| {
            calls.mcp_servers(id.0).map(Json).map_err(|error| failure(&ctx, &error))
        })?,
    )?;
    Ok(())
}

/// Add `sessionPutBlob(id, bytes)`. The bytes come as a `Uint8Array`, not as JSON, so the call copies them before the
/// task runs.
fn add_put_blob<'js>(object: &Object<'js>, sessions: &Rc<dyn Sessions>, queue: &Queue<'js>) -> rquickjs::Result<()> {
    let sessions = Rc::clone(sessions);
    let queue = queue.clone();
    object.set(
        "sessionPutBlob",
        Function::new(
            object.ctx().clone(),
            move |ctx: Ctx<'js>, id: Json<SessionId>, bytes: TypedArray<'js, u8>| -> rquickjs::Result<Promise<'js>> {
                let bytes = crate::bytes::copy(&bytes)?;
                let sessions = Rc::clone(&sessions);
                let (promise, _abort) = queue.request(
                    &ctx,
                    async move { sessions.put_blob(id.0, bytes).await },
                    |ctx, result| joined(ctx, result).map(Json),
                )?;
                Ok(promise)
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

/// Adds the asynchronous requests: each one takes its arguments as one JSON value, runs as a local task, and answers a
/// promise of its JSON.
struct Requests<'js> {
    sessions: Rc<dyn Sessions>,
    queue: Queue<'js>,
}

impl<'js> Requests<'js> {
    fn add<A, T, F>(
        &self,
        object: &Object<'js>,
        name: &str,
        run: impl Fn(Rc<dyn Sessions>, A) -> F + 'js,
    ) -> rquickjs::Result<()>
    where
        A: DeserializeOwned + 'js,
        T: Serialize + 'static,
        F: Future<Output = Result<T, SessionsError>> + 'static,
    {
        let sessions = Rc::clone(&self.sessions);
        let queue = self.queue.clone();
        object.set(
            name,
            Function::new(
                object.ctx().clone(),
                move |ctx: Ctx<'js>, arguments: Json<A>| -> rquickjs::Result<Promise<'js>> {
                    let (promise, _abort) =
                        queue.request(&ctx, run(Rc::clone(&sessions), arguments.0), |ctx, result| {
                            joined(ctx, result).map(Json)
                        })?;
                    Ok(promise)
                },
            )?,
        )
    }

    /// Add a request as [`Requests::add`] does, which answers an operation. Its `cancel` drops the task, so a child
    /// process of the task stops, and the promise rejects with `{ cancelled: true }`.
    fn add_operation<A, T, F>(
        &self,
        object: &Object<'js>,
        name: &str,
        run: impl Fn(Rc<dyn Sessions>, A) -> F + 'js,
    ) -> rquickjs::Result<()>
    where
        A: DeserializeOwned + 'js,
        T: Serialize + 'static,
        F: Future<Output = Result<T, SessionsError>> + 'static,
    {
        let sessions = Rc::clone(&self.sessions);
        let queue = self.queue.clone();
        object.set(
            name,
            Function::new(
                object.ctx().clone(),
                move |ctx: Ctx<'js>, arguments: Json<A>| -> rquickjs::Result<Operation<'js>> {
                    let (promise, abort) = queue.request(
                        &ctx,
                        run(Rc::clone(&sessions), arguments.0),
                        |ctx, result| match result {
                            Err(error) if error.is_cancelled() => {
                                Err(ctx.throw(Cancelled { cancelled: true }.into_js(ctx)?))
                            }
                            result => joined(ctx, result).map(Json),
                        },
                    )?;
                    let cancel = Function::new(ctx, move || abort.abort())?;
                    Ok(Operation { promise, cancel })
                },
            )?,
        )
    }
}
