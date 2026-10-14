//! The session boundary between engine facts and saved event positions.

use std::sync::Mutex;

use yuke_engine::{Commit, Observer, TurnEvent};
use yuke_protocol::{
    BlockPosition, DraftDiscardReason, DraftId, EventNumber, LiveUpdate, SessionId, SessionUpdate, SessionUpdateParams,
    StoredEvent,
};

use crate::lock;

/// Receives typed session updates without a wait. RPC and in-process clients use the same facts.
/// A callback must not block. The caller owns delivery queues and serialization.
pub trait SessionObserver: Send + Sync {
    /// Receive a saved event or a live fact of its session.
    fn update(&self, update: SessionUpdateParams);
}

impl<F: Fn(SessionUpdateParams) + Send + Sync> SessionObserver for F {
    fn update(&self, update: SessionUpdateParams) {
        self(update);
    }
}

pub(crate) struct Updates<'a> {
    session_id: SessionId,
    observer: Option<&'a dyn SessionObserver>,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    draft: Option<Draft>,
    execution_event: Option<EventNumber>,
    ended: bool,
}

struct Draft {
    id: DraftId,
    blocks: Vec<yuke_ai::BlockId>,
    ready: bool,
}

impl<'a> Updates<'a> {
    pub(crate) fn new(session_id: SessionId, observer: Option<&'a dyn SessionObserver>) -> Self {
        Self {
            session_id,
            observer,
            state: Mutex::default(),
        }
    }

    fn emit(&self, update: SessionUpdate) {
        if let Some(observer) = self.observer {
            observer.update(SessionUpdateParams {
                session_id: self.session_id,
                update,
            });
        }
    }

    fn live(&self, update: LiveUpdate) {
        self.emit(SessionUpdate::Live(update));
    }

    fn discard(&self, reason: DraftDiscardReason) {
        let draft = lock(&self.state).draft.take();
        if let Some(draft) = draft {
            self.live(LiveUpdate::DraftDiscarded {
                draft_id: draft.id,
                reason,
            });
        }
    }

    /// Publish only after the store confirms its write, before the next engine step.
    pub(crate) fn committed(
        &self,
        event_number: EventNumber,
        commit: &Commit<'_>,
        consumed: Vec<yuke_protocol::InputId>,
    ) {
        if self.observer.is_none() {
            return;
        }
        let draft = {
            let mut state = lock(&self.state);
            state.ended = commit.end.is_some();
            if commit
                .blocks
                .iter()
                .any(|block| matches!(block, yuke_ai::Block::ToolCall(_)))
            {
                state.execution_event = Some(event_number);
            }
            if state.draft.as_ref().is_some_and(|draft| draft.ready) {
                state.draft.take()
            } else {
                None
            }
        };
        self.emit(SessionUpdate::Saved(StoredEvent {
            event_number,
            event: yuke_protocol::SessionEvent::Commit {
                commit: commit.clone().into_owned(),
                consumed,
            },
        }));
        if let Some(draft) = draft {
            self.live(LiveUpdate::DraftCommitted {
                draft_id: draft.id,
                event_number,
                blocks: draft.blocks,
            });
        }
    }

    #[expect(
        clippy::expect_used,
        reason = "the engine saves each answer before it emits tool events"
    )]
    fn execution(&self, block_index: usize) -> BlockPosition {
        BlockPosition {
            event_number: lock(&self.state).execution_event.expect("a tool has a saved call"),
            block_index,
        }
    }
}

impl Observer for Updates<'_> {
    #[expect(
        clippy::expect_used,
        reason = "the engine emits a response start before model events or cancellation"
    )]
    fn event(&self, event: &TurnEvent<'_>) {
        if self.observer.is_none() {
            return;
        }
        match event {
            TurnEvent::ResponseStarted => {
                let draft_id = DraftId::generate();
                lock(&self.state).draft = Some(Draft {
                    id: draft_id,
                    blocks: Vec::new(),
                    ready: false,
                });
                self.live(LiveUpdate::DraftStarted { draft_id });
            }
            TurnEvent::ResponseFailed(_) => self.discard(DraftDiscardReason::Failed),
            TurnEvent::ResponseCancelled { blocks } => {
                let mut state = lock(&self.state);
                let draft = state.draft.as_mut().expect("a response has a draft");
                // The engine omits reasoning from cancelled context. Reply supplies the other retained blocks.
                draft.blocks = blocks
                    .iter()
                    .filter_map(|block| {
                        (!matches!(block.content, yuke_ai::Partial::Reasoning(_))).then_some(block.block)
                    })
                    .collect();
                draft.ready = true;
            }
            TurnEvent::Model(event) => {
                let draft_id = {
                    let mut state = lock(&self.state);
                    let draft = state.draft.as_mut().expect("a response has a draft");
                    match event {
                        yuke_ai::Event::BlockStopped(stopped) => draft.blocks.push(stopped.block),
                        yuke_ai::Event::Done(_) => {
                            draft.blocks.sort_unstable();
                            draft.ready = true;
                        }
                        yuke_ai::Event::BlockStarted(_)
                        | yuke_ai::Event::TextDelta(_)
                        | yuke_ai::Event::RefusalDelta(_)
                        | yuke_ai::Event::ReasoningDelta(_)
                        | yuke_ai::Event::ToolInputDelta(_)
                        | yuke_ai::Event::ReasoningSectionStarted(_) => {}
                    }
                    draft.id
                };
                self.live(LiveUpdate::Model {
                    draft_id,
                    event: (*event).into(),
                });
            }
            TurnEvent::ToolStarted { block_index, call } => self.live(LiveUpdate::ToolStarted {
                execution: self.execution(*block_index),
                call: (*call).clone(),
            }),
            TurnEvent::ToolOutput { block_index, text } => self.live(LiveUpdate::ToolOutput {
                execution: self.execution(*block_index),
                text: (*text).to_owned(),
            }),
            TurnEvent::ToolFinished { block_index, result } => self.live(LiveUpdate::ToolFinished {
                execution: self.execution(*block_index),
                result: (*result).clone(),
            }),
            TurnEvent::RetryScheduled { after, error } => self.live(LiveUpdate::RetryScheduled {
                after_ms: u64::try_from(after.as_millis()).unwrap_or(u64::MAX),
                error: error.to_string(),
            }),
            TurnEvent::RoundFailed(error) => self.live(LiveUpdate::RoundFailed {
                error: error.to_string(),
            }),
        }
    }
}

impl Drop for Updates<'_> {
    fn drop(&mut self) {
        // A dropped future or an uncertain write leaves no confirmed replacement for its draft.
        self.discard(DraftDiscardReason::Unconfirmed);
        if !lock(&self.state).ended {
            self.live(LiveUpdate::TurnUnconfirmed);
        }
    }
}
