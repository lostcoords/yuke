//! The sessions and the catalog of the app for the plugins: `ctx.get("sessions")` and `ctx.get("catalog")`.

use std::sync::{Arc, Weak};

use async_trait::async_trait;
use yuke_js::{Sessions, SessionsError, ViewSink};
use yuke_protocol::{
    EventNumber, Input, InputId, InteractionId, InteractionResponse, Job, ListCatalogResult, ListSessionsParams,
    ListSessionsResult, McpServer, SessionId, SessionRow, SessionSettings, StoredEvent,
};

use super::sessions::SessionService;
use super::{AppError, Shared};

/// The sessions of the app for one runtime. The service can end before the runtime, so each call upgrades it.
pub(super) struct PluginSessions {
    pub(super) service: Weak<SessionService>,
    pub(super) shared: Arc<Shared>,
}

impl PluginSessions {
    fn service(&self) -> Result<Arc<SessionService>, AppError> {
        self.service.upgrade().ok_or(AppError::Stopped)
    }
}

#[async_trait]
impl Sessions for PluginSessions {
    async fn create(&self, settings: SessionSettings) -> Result<SessionId, SessionsError> {
        Ok(self.service()?.create(settings).await?)
    }

    async fn fork(&self, id: SessionId, through: Option<EventNumber>) -> Result<SessionId, SessionsError> {
        Ok(self.service()?.fork(id, through).await?)
    }

    async fn list(&self, params: ListSessionsParams) -> Result<ListSessionsResult, SessionsError> {
        Ok(self.service()?.list(params).await?)
    }

    async fn get(&self, id: SessionId) -> Result<SessionRow, SessionsError> {
        Ok(self.service()?.get(id).await?)
    }

    async fn remove(&self, id: SessionId) -> Result<(), SessionsError> {
        Ok(self.service()?.remove(id).await?)
    }

    async fn open(&self, id: SessionId, tail: usize, sink: ViewSink) -> Result<Box<dyn Send>, SessionsError> {
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

    async fn remove_input(&self, id: SessionId, input_id: InputId) -> Result<(), SessionsError> {
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

    async fn stop_job(&self, id: SessionId, job_id: String) -> Result<(), SessionsError> {
        Ok(self.service()?.stop_job(id, &job_id).await?)
    }

    fn mcp_servers(&self, id: SessionId) -> Result<Vec<McpServer>, SessionsError> {
        Ok(self.service()?.mcp_servers(id)?)
    }

    async fn close(&self, id: SessionId, stop_jobs: bool) -> Result<(), SessionsError> {
        Ok(self.service()?.close(id, stop_jobs).await?)
    }

    async fn catalog(&self, all: bool) -> Result<ListCatalogResult, SessionsError> {
        Ok(self.shared.catalog(all).await?)
    }
}
