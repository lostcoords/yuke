//! The facts of the app for `ctx.on` of the plugins: each update of each open session, its open and its close, and
//! each notice. A watch holds no session.

use std::cell::Cell;
use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::{Rc, Weak};

use tokio::sync::oneshot;
use yuke_js::{Fact, FactSink};
use yuke_protocol::{
    ExtensionRequestParams, InteractionId, Job, NoticeParams, ServerNotification, SessionId, SessionState,
};

use super::{Answer, Observer};

/// The watches of the facts. A watch gets [`Fact::Update`] and [`Fact::Closed`] of a session only after
/// [`Fact::Opened`] of that session.
#[derive(Default)]
pub(super) struct Facts {
    watchers: RefCell<Vec<Watcher>>,
    last: Cell<u64>,
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
        let sinks: Vec<_> = self
            .watchers
            .borrow()
            .iter()
            .filter(|watcher| watcher.known.contains(&session))
            .map(|watcher| Rc::clone(&watcher.sink))
            .collect();
        for sink in sinks {
            sink(Fact::Update {
                session_id: session,
                update: Box::new(update.clone()),
            });
        }
    }

    /// Tell each watch, or only the watch `only`, that `session` is open with `parent`, `state`, `jobs`, and
    /// `questions`. A watch that knows the session already gets nothing.
    pub(super) fn opened(
        &self,
        session: SessionId,
        parent: Option<SessionId>,
        state: SessionState,
        jobs: &[Job],
        questions: &[InteractionId],
        only: Option<u64>,
    ) {
        let sinks: Vec<_> = self
            .watchers
            .borrow_mut()
            .iter_mut()
            .filter_map(|watcher| {
                if only.is_some_and(|id| id != watcher.id) || !watcher.known.insert(session) {
                    None
                } else {
                    Some(Rc::clone(&watcher.sink))
                }
            })
            .collect();
        for sink in sinks {
            sink(Fact::Opened {
                session_id: session,
                parent,
                state,
                jobs: jobs.to_vec(),
                questions: questions.to_vec(),
            });
        }
    }

    /// Tell each watch that knows `session` that it closed.
    pub(super) fn closed(&self, session: SessionId) {
        let sinks: Vec<_> = self
            .watchers
            .borrow_mut()
            .iter_mut()
            .filter_map(|watcher| watcher.known.remove(&session).then(|| Rc::clone(&watcher.sink)))
            .collect();
        for sink in sinks {
            sink(Fact::Closed { session_id: session });
        }
    }

    /// Give `notice` to each watch.
    fn notice(&self, notice: &NoticeParams) {
        let sinks: Vec<_> = self
            .watchers
            .borrow()
            .iter()
            .map(|watcher| Rc::clone(&watcher.sink))
            .collect();
        for sink in sinks {
            sink(Fact::Notice(notice.clone()));
        }
    }

    /// Start a watch with `sink`. It knows no session yet; the caller gives it the open ones.
    pub(super) fn watch(self: &Rc<Self>, sink: FactSink) -> Watch {
        let id = self.last.get() + 1;
        self.last.set(id);
        self.watchers.borrow_mut().push(Watcher {
            id,
            sink,
            known: HashSet::new(),
        });
        Watch {
            facts: Rc::downgrade(self),
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
            facts.watchers.borrow_mut().retain(|watcher| watcher.id != self.id);
        }
    }
}

/// The observer of the app with each notice also as a fact. Every notice of the app goes through it.
pub(super) struct Noticed {
    pub(super) observer: Rc<dyn Observer>,
    pub(super) facts: Rc<Facts>,
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

#[cfg(test)]
mod tests {
    use super::*;
    use yuke_protocol::{LiveUpdate, NoticeLevel, SessionUpdate};

    #[test]
    fn a_fact_callback_can_change_watches_and_only_known_sessions_get_updates() {
        let facts = Rc::new(Facts::default());
        let events = Rc::new(RefCell::new(Vec::new()));
        let kept = Rc::clone(&events);
        let weak = Rc::downgrade(&facts);
        let watch = facts.watch(Rc::new(move |fact| {
            let facts = weak.upgrade().unwrap();
            drop(facts.watch(Rc::new(|_| {})));
            kept.borrow_mut().push(fact);
        }));
        let session = SessionId::generate();
        let update = SessionUpdate::Live(LiveUpdate::State {
            state: SessionState::Running,
        });
        let notice = NoticeParams {
            session_id: None,
            level: NoticeLevel::Info,
            source: "test".to_owned(),
            message: "ready".to_owned(),
        };
        facts.update(session, &update);
        facts.opened(session, None, SessionState::Idle, &[], &[], Some(watch.id));
        facts.opened(session, None, SessionState::Idle, &[], &[], None);
        facts.update(session, &update);
        facts.closed(session);
        facts.update(session, &update);
        facts.notice(&notice);
        drop(watch);
        facts.notice(&notice);

        assert_eq!(
            *events.borrow(),
            [
                Fact::Opened {
                    session_id: session,
                    parent: None,
                    state: SessionState::Idle,
                    jobs: Vec::new(),
                    questions: Vec::new()
                },
                Fact::Update {
                    session_id: session,
                    update: Box::new(update)
                },
                Fact::Closed { session_id: session },
                Fact::Notice(notice),
            ]
        );
    }
}
