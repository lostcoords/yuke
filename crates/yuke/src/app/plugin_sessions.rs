//! The sessions and the catalog of the app for the plugins, `ctx.get("sessions")` and `ctx.get("catalog")`, and the
//! credentials and the plugin manager for the bundled plugins `login` and `plugins`.

use std::any::Any;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::{Rc, Weak};

use async_trait::async_trait;
use tokio::sync::oneshot;
use yuke_js::{FactSink, Sessions, SessionsError, ViewSink};
use yuke_protocol::{
    ApplyPluginsParams, ApplyPluginsResult, CheckPluginsParams, CheckPluginsResult, EventNumber, Input, InputId,
    InteractionId, InteractionResponse, Job, JobId, ListCatalogResult, ListPluginsResult, ListSessionsParams,
    ListSessionsResult, LoginId, LoginOutcome, LoginResult, McpServer, SessionId, SessionRow, SessionSettings,
    SessionTitle, SetApiKeyParams, StoredEvent, SyncPluginsParams, SyncPluginsResult,
};

use super::sessions::SessionService;
use super::{AppError, Shared};

/// The sessions of the app for one runtime. The service can end before the runtime, so each call upgrades it.
pub(super) struct PluginSessions {
    pub(super) service: Weak<SessionService>,
    pub(super) shared: Rc<Shared>,
    /// The end of each login of the plugins that no call waits for yet. It keeps the end of a login that has ended.
    pub(super) login_ends: RefCell<HashMap<LoginId, oneshot::Receiver<LoginOutcome>>>,
}

impl PluginSessions {
    fn service(&self) -> Result<Rc<SessionService>, AppError> {
        self.service.upgrade().ok_or(AppError::Stopped)
    }
}

#[async_trait(?Send)]
impl Sessions for PluginSessions {
    async fn create(&self, settings: SessionSettings, parent: Option<SessionId>) -> Result<SessionId, SessionsError> {
        Ok(self.service()?.create(settings, parent).await?)
    }

    async fn fork(
        &self,
        id: SessionId,
        through: Option<EventNumber>,
        cwd: Option<std::path::PathBuf>,
    ) -> Result<SessionId, SessionsError> {
        Ok(self.service()?.fork(id, through, cwd).await?)
    }

    async fn list(&self, params: ListSessionsParams) -> Result<ListSessionsResult, SessionsError> {
        Ok(self.service()?.list(params).await?)
    }

    async fn inspect(&self, id: SessionId) -> Result<yuke_js::SessionInspection, SessionsError> {
        Ok(self.service()?.live(id)?.inspect().await?)
    }

    async fn get(&self, id: SessionId) -> Result<SessionRow, SessionsError> {
        Ok(self.service()?.get(id).await?)
    }

    async fn remove(&self, id: SessionId) -> Result<(), SessionsError> {
        Ok(self.service()?.remove(id).await?)
    }

    async fn open(&self, id: SessionId, tail: usize, sink: ViewSink) -> Result<Box<dyn Any>, SessionsError> {
        let service = self.service()?;
        // The hold comes before the view, so the session does not count down while the view reads.
        let attachment = if let Ok(attachment) = service.attach(id) {
            attachment
        } else {
            service.open(id, |_, _| Ok(None)).await?;
            service.attach(id)?
        };
        let view = service.view(id, tail, sink).await?;
        Ok(Box::new((attachment, view)))
    }

    fn watch_facts(&self, sink: FactSink) -> Box<dyn Any> {
        match self.service() {
            Ok(service) => Box::new(service.watch_facts(sink)),
            // After the shutdown, no session opens, so the watch gets nothing.
            Err(_) => Box::new(()),
        }
    }

    async fn events_before(
        &self,
        id: SessionId,
        before: Option<EventNumber>,
        limit: usize,
    ) -> Result<Vec<StoredEvent>, SessionsError> {
        Ok(self.service()?.events_before(id, before, limit).await?)
    }

    async fn input(&self, id: SessionId, input: Input) -> Result<InputId, SessionsError> {
        Ok(self.service()?.input(id, input).await?)
    }

    fn background(&self, id: SessionId) {
        if let Ok(service) = self.service() {
            service.background(id);
        }
    }

    fn has_movable(&self, id: SessionId) -> bool {
        self.service().is_ok_and(|service| service.has_movable(id))
    }

    fn cancel(&self, id: SessionId) {
        if let Ok(service) = self.service() {
            service.cancel(id);
        }
    }

    async fn idle(&self, id: SessionId) -> Result<(), SessionsError> {
        Ok(self.service()?.idle(id).await?)
    }

    async fn set_settings(&self, id: SessionId, settings: SessionSettings) -> Result<(), SessionsError> {
        Ok(self.service()?.set_settings(id, settings).await?)
    }

    async fn rename(&self, id: SessionId, title: SessionTitle) -> Result<(), SessionsError> {
        Ok(self.service()?.rename(id, title).await?)
    }

    async fn put_blob(&self, id: SessionId, bytes: Vec<u8>) -> Result<yuke_ai::Blob, SessionsError> {
        Ok(self.service()?.put_blob(id, bytes).await?)
    }

    async fn remove_input(&self, id: SessionId, input_id: InputId) -> Result<bool, SessionsError> {
        Ok(self.service()?.remove_input(id, input_id).await?)
    }

    fn respond(
        &self,
        id: SessionId,
        interaction_id: InteractionId,
        response: InteractionResponse,
    ) -> Result<(), SessionsError> {
        Ok(self.service()?.respond(id, interaction_id, response)?)
    }

    fn jobs(&self, id: SessionId) -> Result<Vec<Job>, SessionsError> {
        Ok(self.service()?.jobs(id)?)
    }

    async fn stop_job(&self, id: SessionId, job_id: &str) -> Result<(), SessionsError> {
        Ok(self.service()?.stop_job(id, &JobId(job_id.to_owned())).await?)
    }

    fn mcp_servers(&self, id: SessionId) -> Result<Vec<McpServer>, SessionsError> {
        Ok(self.service()?.mcp_servers(id)?)
    }

    async fn close(&self, id: SessionId) -> Result<(), SessionsError> {
        Ok(self.service()?.close(id).await?)
    }

    async fn catalog(&self, all: bool) -> Result<ListCatalogResult, SessionsError> {
        Ok(self.shared.catalog(all).await?)
    }

    async fn login(&self, provider: String) -> Result<LoginResult, SessionsError> {
        let (result, end) = self.shared.login(provider).await?;
        self.login_ends.borrow_mut().insert(result.login_id, end);
        Ok(result)
    }

    async fn wait_for_login(&self, id: LoginId) -> Result<LoginOutcome, SessionsError> {
        let end = self.login_ends.borrow_mut().remove(&id).ok_or(AppError::NoLogin(id))?;
        Ok(end
            .await
            .map_err(|error| AppError::Internal(format!("the login task failed: {error}")))?)
    }

    fn cancel_login(&self, id: LoginId) {
        if self.shared.cancel_login(id).is_err() {
            // The login ended, so it has nothing to stop.
        }
    }

    async fn set_api_key(&self, params: SetApiKeyParams) -> Result<(), SessionsError> {
        Ok(self.shared.set_api_key(&params.provider, params.api_key).await?)
    }

    async fn logout(&self, provider: String) -> Result<(), SessionsError> {
        Ok(self.shared.logout(&provider).await?)
    }

    async fn list_plugins(&self) -> Result<ListPluginsResult, SessionsError> {
        Ok(self.shared.list_plugins()?)
    }

    async fn sync_plugins(&self, params: SyncPluginsParams) -> Result<SyncPluginsResult, SessionsError> {
        Ok(self.shared.sync_plugins(params).await?)
    }

    async fn check_plugins(&self, params: CheckPluginsParams) -> Result<CheckPluginsResult, SessionsError> {
        Ok(self.shared.check_plugins(params).await?)
    }

    async fn apply_plugins(&self, params: ApplyPluginsParams) -> Result<ApplyPluginsResult, SessionsError> {
        Ok(self.shared.apply_plugins(params).await?)
    }

    async fn add_plugin(
        &self,
        params: yuke_protocol::AddPluginParams,
    ) -> Result<yuke_protocol::AddPluginResult, SessionsError> {
        Ok(self.shared.add_plugin(params).await?)
    }

    async fn remove_plugin(&self, params: yuke_protocol::RemovePluginParams) -> Result<(), SessionsError> {
        Ok(self.shared.remove_plugin(params).await?)
    }
}
