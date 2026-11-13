//! The session boundary between engine facts and saved event positions.

use std::cell::RefCell;

use yuke_engine::{Commit, Observer, TurnEvent, chain_text};
use yuke_protocol::{
    BlockPosition, DraftDiscardReason, DraftId, EventNumber, LiveUpdate, ModelUpdate, SessionUpdate, StoredEvent,
};

/// Receives typed session updates without a wait. RPC and in-process clients use the same facts.
/// A callback must not block. The caller owns delivery queues and serialization.
pub trait SessionObserver {
    /// Receive a saved event or a live fact of its session.
    fn update(&self, update: SessionUpdate);
}

impl<F: Fn(SessionUpdate)> SessionObserver for F {
    fn update(&self, update: SessionUpdate) {
        self(update);
    }
}

pub(crate) struct Updates<'a> {
    observer: Option<&'a dyn SessionObserver>,
    state: RefCell<State>,
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
}

impl<'a> Updates<'a> {
    pub(crate) fn new(observer: Option<&'a dyn SessionObserver>) -> Self {
        Self {
            observer,
            state: RefCell::default(),
        }
    }

    fn emit(&self, update: SessionUpdate) {
        if let Some(observer) = self.observer {
            observer.update(update);
        }
    }

    fn live(&self, update: LiveUpdate) {
        self.emit(SessionUpdate::Live(update));
    }

    fn discard(&self, reason: DraftDiscardReason) {
        let draft = self.state.borrow_mut().draft.take();
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
        consumed: Vec<yuke_protocol::ConsumedInput>,
    ) {
        if self.observer.is_none() {
            return;
        }
        let draft = {
            let mut state = self.state.borrow_mut();
            state.ended = commit.end.is_some();
            if commit
                .blocks
                .iter()
                .any(|block| matches!(block, yuke_ai::Block::ToolCall(_)))
            {
                state.execution_event = Some(event_number);
            }
            // The engine saves an answer only after its response ends, so a draft is complete when its commit comes.
            state.draft.take()
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
    fn position(&self, block_index: usize) -> BlockPosition {
        BlockPosition {
            event_number: self.state.borrow().execution_event.expect("a tool has a saved call"),
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
                self.state.borrow_mut().draft = Some(Draft {
                    id: draft_id,
                    blocks: Vec::new(),
                });
                self.live(LiveUpdate::DraftStarted { draft_id });
            }
            TurnEvent::ResponseFailed(_) => self.discard(DraftDiscardReason::Failed),
            TurnEvent::ResponseCancelled { blocks } => {
                let mut state = self.state.borrow_mut();
                let draft = state.draft.as_mut().expect("a response has a draft");
                draft.blocks = blocks.iter().map(|block| block.block).collect();
            }
            TurnEvent::Model(event) => {
                let draft_id = {
                    let mut state = self.state.borrow_mut();
                    let draft = state.draft.as_mut().expect("a response has a draft");
                    match event {
                        yuke_ai::Event::BlockStopped(stopped) => draft.blocks.push(stopped.block),
                        yuke_ai::Event::Done(_) => draft.blocks.sort_unstable(),
                        _ => {}
                    }
                    draft.id
                };
                self.live(LiveUpdate::Model {
                    draft_id,
                    event: ModelUpdate::from_event(*event),
                });
            }
            TurnEvent::ToolStarted { block_index, call } => self.live(LiveUpdate::ToolStarted {
                position: self.position(*block_index),
                call: (*call).clone(),
            }),
            TurnEvent::ToolOutput { block_index, text } => self.live(LiveUpdate::ToolOutput {
                position: self.position(*block_index),
                text: (*text).to_owned(),
            }),
            TurnEvent::ToolFinished {
                block_index,
                result,
                display,
                duration,
            } => self.live(LiveUpdate::ToolFinished {
                position: self.position(*block_index),
                result: (*result).clone(),
                display: display.to_vec(),
                duration_ms: duration.map(|duration| u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)),
            }),
            TurnEvent::RetryScheduled { after, error } => self.live(LiveUpdate::RetryScheduled {
                after_ms: u64::try_from(after.as_millis()).unwrap_or(u64::MAX),
                error: error.to_string(),
            }),
            // The saved end of a failed turn keeps each cause, so the live text keeps them too.
            TurnEvent::RoundFailed(error) => self.live(LiveUpdate::RoundFailed {
                error: chain_text(error),
            }),
        }
    }
}

impl Drop for Updates<'_> {
    fn drop(&mut self) {
        // A dropped future or an uncertain write leaves no confirmed replacement for its draft.
        self.discard(DraftDiscardReason::Unconfirmed);
        if !self.state.borrow().ended {
            self.live(LiveUpdate::TurnUnconfirmed);
        }
    }
}
