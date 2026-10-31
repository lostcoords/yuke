//! The facts of the app for `ctx.on` of the plugins: each update of each open session, its open and its close, and
//! each notice. A watch holds no session.

use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};

use tokio::sync::oneshot;
use yuke_js::{Fact, FactSink};
use yuke_protocol::{ExtensionRequestParams, InteractionId, NoticeParams, ServerNotification, SessionId, SessionState};

use super::{Answer, Observer, lock};

/// The watches of the facts. A watch gets [`Fact::Update`] and [`Fact::Closed`] of a session only after
/// [`Fact::Opened`] of that session.
#[derive(Default)]
pub(super) struct Facts {
    watchers: Mutex<Vec<Watcher>>,
    /// The number of watches, so an update without a watch takes no lock.
    count: AtomicUsize,
    last: AtomicU64,
}

struct Watcher {
    id: u64,
    sink: FactSink,
    /// The sessions that the watch got as open and not yet as closed.
    known: HashSet<SessionId>,
}

impl Facts {
    /// Give `update` of `session` to each watch that knows the session.
    pub(super) fn update(&self, session: SessionId, update: &yuke_protocol::SessionUpdate) {
        if self.count.load(Ordering::Acquire) == 0 {
            return;
        }
        for watcher in lock(&self.watchers)
            .iter()
            .filter(|watcher| watcher.known.contains(&session))
        {
            (watcher.sink)(Fact::Update {
                session_id: session,
                update: Box::new(update.clone()),
            });
        }
    }

    /// Tell each watch, or only the watch `only`, that `session` is open with `state` and `questions`. A watch that
    /// knows the session already gets nothing.
    pub(super) fn opened(
        &self,
        session: SessionId,
        state: SessionState,
        questions: &[InteractionId],
        only: Option<u64>,
    ) {
        for watcher in lock(&self.watchers).iter_mut() {
            if only.is_some_and(|id| id != watcher.id) || !watcher.known.insert(session) {
                continue;
            }
            (watcher.sink)(Fact::Opened {
                session_id: session,
                state,
                questions: questions.to_vec(),
            });
        }
    }

    /// Tell each watch that knows `session` that it closed.
    pub(super) fn closed(&self, session: SessionId) {
        for watcher in lock(&self.watchers).iter_mut() {
            if watcher.known.remove(&session) {
                (watcher.sink)(Fact::Closed { session_id: session });
            }
        }
    }

    /// Give `notice` to each watch.
    fn notice(&self, notice: &NoticeParams) {
        if self.count.load(Ordering::Acquire) == 0 {
            return;
        }
        for watcher in lock(&self.watchers).iter() {
            (watcher.sink)(Fact::Notice(notice.clone()));
        }
    }

    /// Start a watch with `sink`. It knows no session yet; the caller gives it the open ones.
    pub(super) fn watch(self: &Arc<Self>, sink: FactSink) -> Watch {
        let id = self.last.fetch_add(1, Ordering::Relaxed) + 1;
        lock(&self.watchers).push(Watcher {
            id,
            sink,
            known: HashSet::new(),
        });
        self.count.fetch_add(1, Ordering::Release);
        Watch {
            facts: Arc::downgrade(self),
            id,
        }
    }
}

/// A watch of the facts. Its drop ends it.
pub(super) struct Watch {
    facts: Weak<Facts>,
    pub(super) id: u64,
}

impl Drop for Watch {
    fn drop(&mut self) {
        if let Some(facts) = self.facts.upgrade() {
            lock(&facts.watchers).retain(|watcher| watcher.id != self.id);
            facts.count.fetch_sub(1, Ordering::Release);
        }
    }
}

/// The observer of the app with each notice also as a fact. Every notice of the app goes through it.
pub(super) struct Noticed {
    pub(super) observer: Arc<dyn Observer>,
    pub(super) facts: Arc<Facts>,
}

impl Observer for Noticed {
    fn notify(&self, notification: ServerNotification) {
        if let ServerNotification::Notice(notice) = &notification {
            self.facts.notice(notice);
        }
        self.observer.notify(notification);
    }

    fn request(&self, params: ExtensionRequestParams) -> Option<(i64, oneshot::Receiver<Answer>)> {
        self.observer.request(params)
    }

    fn cancel_request(&self, id: i64) {
        self.observer.cancel_request(id);
    }
}
