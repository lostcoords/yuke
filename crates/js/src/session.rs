//! These types open, use, and close one session of the plugins. Its tools are the tools of yuke and the tools that the
//! `session` exports define. Its hooks are the hooks that the `session` exports add.

use std::rc::Rc;
use std::sync::Arc;

use rquickjs::convert::List;
use rquickjs::{Ctx, Function, Object, Promise};
use yuke_agent::PromptSection;
use yuke_engine::CancellationToken;

use crate::Runtime;
use crate::error::{Error, caught};
use crate::plugins::loader;
use crate::processes::Processes;
use crate::runtime::Caller;
use crate::tools::{self, Registry, ScriptTool, SessionHost};

/// An open session of the plugins. Call [`ScriptSession::close`] to await the cleanups. A drop posts the close and does
/// not wait. The posted close runs only while the runtime thread runs, so close each session before a shutdown.
pub struct ScriptSession {
    caller: Caller,
    processes: Arc<Processes>,
    host: Arc<dyn SessionHost>,
    /// The open number of the registry. A new open of the same session gets a new number, so a late close of this
    /// handle never reaches it.
    open: u64,
}

impl std::fmt::Debug for ScriptSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ScriptSession")
            .field("session", &self.host.session_id())
            .field("open", &self.open)
            .finish_non_exhaustive()
    }
}

impl Runtime {
    /// Open the session of `host`: start `session(s)` of each loaded plugin. The open does not wait for them;
    /// [`ScriptSession::tools`] does. Keep `host` for the whole session: its jobs belong to it.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Folder`] when the folder of `host` is not UTF-8, and [`Error::Stopped`] when the thread has
    /// ended.
    pub async fn open_session(&self, host: Arc<dyn SessionHost>) -> Result<ScriptSession, Error> {
        let folder = host.folder();
        let folder = folder.to_str().ok_or_else(|| Error::Folder(folder.clone()))?.to_owned();
        let session_id = host.session_id().to_string();
        let open = self
            .caller
            .run(async move |ctx: Ctx<'_>, registry: Rc<Registry>| {
                let open_session: Function<'_> = caught(&ctx, loader(&ctx).await?.get("openSession"))?;
                let open = registry.open();
                if let Err(error) = caught(&ctx, open_session.call::<_, ()>((open, session_id, folder))) {
                    registry.close(open);
                    return Err(error);
                }
                Ok(open)
            })
            .await?;
        Ok(ScriptSession {
            caller: self.caller.clone(),
            processes: Arc::clone(&self.processes),
            host,
            open,
        })
    }
}

impl ScriptSession {
    /// Wait until `session(s)` of each plugin settles, then return the tools of the session, each with its definition:
    /// the tools of yuke and the tools that the plugins defined. A closed session has no tools. A drop of the wait leaves
    /// the plugins running.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Stopped`] when the thread has ended.
    pub async fn tools(&self) -> Result<Vec<(yuke_ai::ToolDefinition, ScriptTool)>, Error> {
        let open = self.open;
        let entries = self
            .caller
            .run(async move |ctx: Ctx<'_>, registry: Rc<Registry>| {
                let ready: Function<'_> = caught(&ctx, loader(&ctx).await?.get("ready"))?;
                let promise: Promise<'_> = caught(&ctx, ready.call((open,)))?;
                caught(&ctx, promise.into_future::<()>().await)?;
                Ok(registry.entries(open))
            })
            .await?;
        Ok(tools::script_tools(
            &self.caller,
            &self.processes,
            &self.host,
            open,
            entries,
        ))
    }

    /// Run the `prompt.build` handlers of the plugins on `sections`, after `session(s)` of each plugin settles. Each
    /// handler sees the edits of the handlers before it. When `token` is cancelled, the call aborts the signal of the
    /// build and returns `sections` at once. A closed session also returns `sections`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Script`] when a handler throws, returns a value, or leaves a section that is not valid. Returns
    /// [`Error::Stopped`] when the thread has ended.
    pub async fn build_prompt(
        &self,
        sections: &[PromptSection],
        token: &CancellationToken,
    ) -> Result<Vec<PromptSection>, Error> {
        let open = self.open;
        // A `List` crosses as an array, so each section is a `[key, text]` pair.
        let pairs: Vec<List<(String, String)>> = sections
            .iter()
            .map(|section| List((section.key.clone(), section.text.clone())))
            .collect();
        let token = token.clone();
        let built = self
            .caller
            .run(async move |ctx: Ctx<'_>, _: Rc<Registry>| {
                let start: Function<'_> = caught(&ctx, loader(&ctx).await?.get("startPromptBuild"))?;
                let started: Object<'_> = caught(&ctx, start.call((open, pairs)))?;
                let promise: Promise<'_> = caught(&ctx, started.get("answer"))?;
                let abort: Function<'_> = caught(&ctx, started.get("abort"))?;
                tokio::select! {
                    answer = promise.into_future::<Vec<List<(String, String)>>>() => caught(&ctx, answer).map(Some),
                    () = token.cancelled() => {
                        caught(&ctx, abort.call::<_, ()>(()))?;
                        Ok(None)
                    }
                }
            })
            .await?;
        Ok(built.map_or_else(
            || sections.to_vec(),
            |pairs| {
                pairs
                    .into_iter()
                    .map(|List((key, text))| PromptSection { key, text })
                    .collect()
            },
        ))
    }

    /// Close the session: its tools stop at once, each signal of its plugins aborts, and the close waits for each
    /// cleanup. A second close, and the drop after a close, do nothing.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Stopped`] when the thread has ended, which also ends the plugins.
    pub async fn close(&self) -> Result<(), Error> {
        let open = self.open;
        self.caller
            .run(async move |ctx: Ctx<'_>, registry: Rc<Registry>| close(&ctx, &registry, open).await)
            .await
    }
}

impl Drop for ScriptSession {
    fn drop(&mut self) {
        let open = self.open;
        let posted = self.caller.post(async move |ctx: Ctx<'_>, registry: Rc<Registry>| {
            if close(&ctx, &registry, open).await.is_err() {
                // Only the end of the engine fails the close, and that end drops the plugins too.
            }
        });
        if posted.is_err() {
            // The thread has ended, so no plugin of the session runs.
        }
    }
}

/// Close the open session `open` on the JavaScript thread: remove its tools, then await `closeSession`.
async fn close(ctx: &Ctx<'_>, registry: &Registry, open: u64) -> Result<(), Error> {
    let close_session: Function<'_> = caught(ctx, loader(ctx).await?.get("closeSession"))?;
    // No await comes between the two steps, so a dropped close cannot remove the tools without the close of the plugins.
    registry.close(open);
    let promise: Promise<'_> = caught(ctx, close_session.call((open,)))?;
    caught(ctx, promise.into_future::<()>().await)
}
