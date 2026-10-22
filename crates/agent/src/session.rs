//! A session that runs turns on its context and saves each commit of a turn in a store.

use std::fmt;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use yuke_engine::{CancellationToken, Commit, Driver, Inbox, Journal, Outcome, RoundError, TurnEnd, TurnError};
use yuke_protocol::{
    ConsumedInput, EventNumber, Input, InputSource, SessionEvent, SessionId, SessionSettings, StoredEvent,
};

use crate::store::{Access, Lease, NewestTurn, Opened, Store, StoreError};
use crate::updates::{SessionObserver, Updates};
use crate::{PromptSection, lock, prompt_text};

/// The result of a call that was open when its turn stopped. The model reads it.
const OUTCOME_UNKNOWN: &str = "The turn stopped before it saved the result of this call. The call can have run.";

/// The failure of a turn that stopped before it saved its end.
const TURN_STOPPED: &str = "the turn stopped before it saved its end";

/// The plugin name of the notes of the session.
const SESSION_SOURCE: &str = "host:session";

/// The note about `newest_turn`, when that turn was cancelled or failed.
fn interruption_note(newest_turn: &NewestTurn) -> Option<Input> {
    match newest_turn {
        NewestTurn::Ended(TurnEnd::Outcome(Outcome::Cancelled)) => Some(Input::notification(
            SESSION_SOURCE,
            "The previous turn was cancelled.",
            "The user cancelled the previous turn before it ended.",
        )),
        NewestTurn::Ended(TurnEnd::Failed(error)) => Some(Input::notification(
            SESSION_SOURCE,
            "The previous turn failed.",
            &format!("The previous turn ended with an error: {error}"),
        )),
        NewestTurn::Empty | NewestTurn::Open | NewestTurn::Ended(TurnEnd::Outcome(_)) => None,
    }
}

/// A session that one writer owns. Each turn runs on the context of the session. The session saves each commit of
/// the turn in its store before the turn goes on.
pub struct Session {
    settings: SessionSettings,
    /// The sections of the system prompt of each turn. They never change.
    prompt: Vec<PromptSection>,
    context: Vec<yuke_ai::Block>,
    store: Arc<dyn Store>,
    id: SessionId,
    /// `None` after a failed or dropped write: memory can be behind the store until [`Session::recover`].
    lease: Option<Lease>,
    /// The newest saved turn. An open turn of the store ends at the open of the session, so it is never open here.
    newest_turn: NewestTurn,
    /// The input tokens of the newest saved answer. The next turn starts from them.
    input_tokens: Option<u64>,
}

impl fmt::Debug for Session {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Session")
            .field("id", &self.id)
            .field("settings", &self.settings)
            .field("context", &self.context)
            .finish_non_exhaustive()
    }
}

/// The journal, the inbox, and the blob store of one turn. The turn owns its input state. A dropped turn drops that
/// state, and the next turn takes the pending inputs again.
struct TurnJournal<'a> {
    inputs: TurnInputs<'a>,
    updates: &'a Updates<'a>,
    /// The input tokens of the newest saved answer: from before the turn, then from each answer that the turn saves.
    input_tokens: Mutex<Option<u64>>,
}

/// The input state of one turn.
struct TurnInputs<'a> {
    store: &'a dyn Store,
    id: SessionId,
    /// The records of the inputs that the turn took and that no saved commit consumed. They are still pending.
    taken: Mutex<Vec<ConsumedInput>>,
}

impl TurnInputs<'_> {
    /// Take each pending input that the turn did not take, and return their model blocks in input order.
    async fn take(&self) -> Result<Vec<yuke_ai::Block>, StoreError> {
        let pending = self.store.pending(self.id).await?;
        let mut taken = lock(&self.taken);
        let mut blocks = Vec::new();
        for input in pending {
            if taken.iter().any(|known| known.id == input.id) {
                continue;
            }
            let (consumed, model_blocks) = input.into_consumed();
            taken.push(consumed);
            blocks.extend(model_blocks);
        }
        Ok(blocks)
    }
}

#[async_trait]
impl Inbox for TurnJournal<'_> {
    async fn take(&self) -> Result<Vec<yuke_ai::Block>, Box<dyn std::error::Error + Send + Sync>> {
        Ok(self.inputs.take().await?)
    }
}

#[async_trait]
impl Journal for TurnJournal<'_> {
    async fn commit(&self, commit: &Commit<'_>) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // The first commit after a take starts with the taken model blocks, so it consumes their inputs. The records
        // leave `taken` before the save. After a failed save, the next turn takes the pending inputs again.
        let TurnInputs { store, id, taken } = &self.inputs;
        let consumed = std::mem::take(&mut *lock(taken));
        let event_number = store.commit(*id, commit, &consumed).await?;
        if let Some(answer) = &commit.answer {
            *lock(&self.input_tokens) = answer.usage.input;
        }
        self.updates.committed(event_number, commit, consumed);
        Ok(())
    }
}

impl yuke_ai::BlobStore for TurnJournal<'_> {
    fn read(
        &self,
        digest: &yuke_ai::Digest,
    ) -> Result<Option<std::borrow::Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
        Ok(self
            .inputs
            .store
            .read_blob(self.inputs.id, digest)?
            .map(std::borrow::Cow::Owned))
    }
}

impl Session {
    /// Create a session in `store` with `settings` and the system prompt sections `prompt`, and own it.
    ///
    /// # Errors
    ///
    /// Returns the error of [`Store::create_session`].
    pub async fn create(
        store: Arc<dyn Store>,
        settings: &SessionSettings,
        prompt: &[PromptSection],
    ) -> Result<Session, StoreError> {
        let opened = store.create_session(settings, prompt).await?;
        Ok(Session::from_opened(store, opened))
    }

    /// Open session `id` of `store`, and own it. A turn that the store holds as open ends as [`TurnEnd::Failed`], and
    /// each call without a result gets an error result. The session starts no turn, so the
    /// pending inputs wait for [`Session::turn`].
    ///
    /// # Errors
    ///
    /// Returns the error of [`Store::open`], or of the commit that ends an open turn.
    pub async fn open(store: Arc<dyn Store>, id: SessionId) -> Result<Session, StoreError> {
        // No observer saw the session yet, so a load of its events shows the end of an open turn.
        let (opened, _) = open_and_end_turn(&*store, id, Access::Write).await?;
        Ok(Session::from_opened(store, opened))
    }

    /// Copy session `source` of `store` up to the end of a completed turn into a new session, and own the copy.
    /// `through` is the event number of that end, and `None` takes the newest one, as in [`Store::fork_session`]. The
    /// source does not change.
    ///
    /// # Errors
    ///
    /// Returns the error of [`Store::fork_session`].
    pub async fn fork(
        store: Arc<dyn Store>,
        source: SessionId,
        through: Option<EventNumber>,
    ) -> Result<Session, StoreError> {
        let opened = store.fork_session(source, through).await?;
        Ok(Session::from_opened(store, opened))
    }

    fn from_opened(store: Arc<dyn Store>, opened: Opened) -> Session {
        Session {
            settings: opened.settings,
            prompt: opened.prompt,
            context: opened.context,
            store,
            id: opened.id,
            lease: opened.lease,
            newest_turn: opened.newest_turn,
            input_tokens: opened.input_tokens,
        }
    }

    /// The id of the session.
    pub fn id(&self) -> SessionId {
        self.id
    }

    /// The current settings.
    pub fn settings(&self) -> &SessionSettings {
        &self.settings
    }

    /// The sections of the system prompt of each turn.
    pub fn prompt(&self) -> &[PromptSection] {
        &self.prompt
    }

    /// The context. A stale session can hold blocks that the store lacks.
    pub fn context(&self) -> &[yuke_ai::Block] {
        &self.context
    }

    /// Whether a failed or dropped write left memory behind the store. A stale session runs no turn and saves no
    /// settings until [`Session::recover`].
    pub fn is_stale(&self) -> bool {
        self.lease.is_none()
    }

    /// Open the session again from the store: its settings, its context, and its lease. A turn that the store holds
    /// as open ends as failed, and the commit of that end returns, because no observer saw it.
    ///
    /// # Errors
    ///
    /// Returns the error of [`Store::open`], for example [`StoreError::Owned`], or of the commit that ends an open
    /// turn. A stale session stays stale.
    pub async fn recover(&mut self) -> Result<Option<StoredEvent>, StoreError> {
        // A session that holds its lease reads under it, so no other writer can take the session in between.
        let access = if self.is_stale() { Access::Write } else { Access::Read };
        let (opened, repair) = open_and_end_turn(&*self.store, self.id, access).await?;
        self.settings = opened.settings;
        self.context = opened.context;
        self.newest_turn = opened.newest_turn;
        self.input_tokens = opened.input_tokens;
        if opened.lease.is_some() {
            self.lease = opened.lease;
        }
        Ok(repair)
    }

    /// Save `settings` as the current settings, and return the event number of the settings event.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError::Stale`] for a stale session, and [`SessionError::Store`] with the error of
    /// [`Store::set_settings`].
    pub async fn set_settings(&mut self, settings: SessionSettings) -> Result<EventNumber, SessionError> {
        if self.is_stale() {
            return Err(SessionError::Stale);
        }
        // The store can save after the caller drops this future. So the future holds the lease, and a dropped write
        // leaves the session stale.
        let lease = self.lease.take();
        let event_number = self.store.set_settings(self.id, &settings).await?;
        self.settings = settings;
        self.lease = lease;
        Ok(event_number)
    }

    /// The next turn with `driver`. The turn takes each pending input as its input. When the turn runs, the session
    /// gives the driver its session settings, session id, journal, inbox, and blob store. These replace the values that
    /// the caller set on the driver.
    pub fn turn<'s>(&'s mut self, driver: Driver<'s>) -> SessionTurn<'s> {
        SessionTurn {
            session: self,
            driver,
            observer: None,
            cancellation_token: CancellationToken::new(),
            prompt: None,
        }
    }
}

/// Open session `id` with `access`, by a caller that owns the session after the open. A turn that the store holds as
/// open ends as failed, and each of its calls without a result gets an error result. Return the saved commit of that
/// end.
async fn open_and_end_turn(
    store: &dyn Store,
    id: SessionId,
    access: Access,
) -> Result<(Opened, Option<StoredEvent>), StoreError> {
    let mut opened = store.open(id, access).await?;
    if !opened.newest_turn.is_open() {
        return Ok((opened, None));
    }
    let results = open_calls(&opened.context)
        .map(|call_id| yuke_ai::Block::ToolResult(yuke_ai::ToolResult::error(call_id, OUTCOME_UNKNOWN)))
        .collect::<Vec<_>>();
    let end = TurnEnd::Failed(TURN_STOPPED.to_owned());
    let repair = Commit {
        replaced: None,
        blocks: std::borrow::Cow::Owned(results),
        answer: None,
        end: Some(end.clone()),
    };
    let event_number = store.commit(opened.id, &repair, &[]).await?;
    opened.context.extend_from_slice(&repair.blocks);
    opened.newest_turn = NewestTurn::Ended(end);
    let event = StoredEvent {
        event_number,
        event: SessionEvent::Commit {
            commit: repair,
            consumed: Vec::new(),
        },
    };
    Ok((opened, Some(event)))
}

/// The ids of the calls in `context` without a result, in call order. One commit saves all results of an answer, so
/// only an answer at the end of the context has calls without a result.
fn open_calls(context: &[yuke_ai::Block]) -> impl Iterator<Item = &str> {
    let answer = context
        .iter()
        .rposition(|block| block.role() == yuke_ai::Role::User)
        .map_or(0, |last_user| last_user + 1);
    context[answer..].iter().filter_map(|block| match block {
        yuke_ai::Block::ToolCall(call) => Some(call.call_id.as_str()),
        _ => None,
    })
}

/// One turn of a session. It does nothing until [`SessionTurn::run`].
#[must_use = "a turn does nothing until the caller runs it"]
pub struct SessionTurn<'s> {
    session: &'s mut Session,
    driver: Driver<'s>,
    observer: Option<&'s dyn SessionObserver>,
    cancellation_token: CancellationToken,
    /// The prompt sections of this turn in place of the saved ones.
    prompt: Option<Vec<PromptSection>>,
}

impl fmt::Debug for SessionTurn<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionTurn")
            .field("session", &self.session.id)
            .field("driver", &self.driver)
            .finish_non_exhaustive()
    }
}

impl<'s> SessionTurn<'s> {
    /// Give each saved commit and live fact of the turn to `observer`.
    pub fn observer(self, observer: &'s dyn SessionObserver) -> Self {
        SessionTurn {
            observer: Some(observer),
            ..self
        }
    }

    /// Stop the turn when `cancellation_token` is cancelled.
    pub fn cancellation_token(self, cancellation_token: CancellationToken) -> Self {
        SessionTurn {
            cancellation_token,
            ..self
        }
    }

    /// Use the system prompt sections `prompt` in this turn. The session does not save them, so the next turn uses the
    /// saved sections again.
    pub fn prompt(self, prompt: Vec<PromptSection>) -> Self {
        SessionTurn {
            prompt: Some(prompt),
            ..self
        }
    }

    /// Run the turn until it ends. After a failed commit, or when the caller drops this future, the session is stale.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError::Stale`] for a stale session, and [`SessionError::NoInput`] when no input waits. Returns
    /// [`SessionError::Round`] when a round fails, and [`SessionError::Store`] when the store fails.
    pub async fn run(self) -> Result<Outcome, SessionError> {
        let SessionTurn {
            session,
            driver,
            observer,
            cancellation_token,
            prompt,
        } = self;
        if session.is_stale() {
            return Err(SessionError::Stale);
        }
        let inputs = TurnInputs {
            store: &*session.store,
            id: session.id,
            taken: Mutex::default(),
        };
        let mut input = inputs.take().await?;
        if input.is_empty() {
            return Err(SessionError::NoInput);
        }
        // The note follows the input that starts the turn, so a note alone never starts a turn. A turn that failed
        // before its first commit leaves its note pending.
        let noted = lock(&inputs.taken)
            .iter()
            .any(|taken| matches!(&taken.source, InputSource::Plugin { name } if name == SESSION_SOURCE));
        if !noted && let Some(note) = interruption_note(&session.newest_turn) {
            session.store.accept_input(session.id, note).await?;
            input.extend(inputs.take().await?);
        }
        // The future holds the lease while the turn runs, so a dropped future releases it.
        let lease = session.lease.take();
        let updates = Updates::new(observer);
        let turn_journal = TurnJournal {
            inputs,
            updates: &updates,
            input_tokens: Mutex::new(session.input_tokens),
        };
        let session_id = session.id.to_string();
        let system = prompt_text(prompt.as_deref().unwrap_or(&session.prompt));
        let turn = driver
            .system(&system)
            .settings(&session.settings.settings)
            .session_id(&session_id)
            .journal(&turn_journal)
            .inbox(&turn_journal)
            .blobs(&turn_journal)
            .turn(&mut session.context, input)
            .input_tokens(session.input_tokens)
            .cancellation_token(cancellation_token)
            .observer(&updates);
        let ran = turn.run().await;
        // A saved answer counts even when a later commit of the turn fails.
        session.input_tokens = *lock(&turn_journal.input_tokens);
        let ran = match ran {
            Ok(outcome) => Ok(outcome),
            Err(TurnError::Round(error)) => Err(error),
            // The commit can have saved or not, so the lease drops, and the session is stale.
            Err(TurnError::Commit(error)) => {
                return Err(SessionError::Store(match error.downcast::<StoreError>() {
                    Ok(error) => *error,
                    Err(error) => StoreError::Failed(error),
                }));
            }
        };
        // The driver gives an outcome or a round error only after the store saved the end of the turn.
        session.newest_turn = NewestTurn::Ended(TurnEnd::from_result(ran.as_ref()));
        session.lease = lease;
        ran.map_err(SessionError::Round)
    }
}

/// Why a turn of a session failed.
#[derive(Debug)]
pub enum SessionError {
    /// A round failed, and no hook sent it again. The store holds the end of the turn.
    Round(RoundError),
    /// The store failed.
    Store(StoreError),
    /// A failed or dropped write left the session behind its store. [`Session::recover`] opens it again.
    Stale,
    /// No input waits, so no turn ran. A removal of the last input can come between a check and the turn.
    NoInput,
}

impl From<StoreError> for SessionError {
    fn from(error: StoreError) -> Self {
        Self::Store(error)
    }
}

impl fmt::Display for SessionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Round(error) => fmt::Display::fmt(error, f),
            Self::Store(error) => fmt::Display::fmt(error, f),
            Self::Stale => f.write_str("a failed write left the session behind its store"),
            Self::NoInput => f.write_str("no input waits"),
        }
    }
}

impl std::error::Error for SessionError {
    // The text is the text of the inner error, so the source is the source of the inner error.
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Round(error) => error.source(),
            Self::Store(error) => error.source(),
            Self::Stale | Self::NoInput => None,
        }
    }
}
