//! A session that runs turns on its context and saves each commit of a turn in a store.

use std::fmt;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use yuke_engine::{CancellationToken, Commit, Driver, Inbox, Journal, Observer, Outcome, TurnEnd, TurnError};

use crate::lock;
use yuke_protocol::{EventNumber, InputId, PendingInput, SessionId, SessionSettings};

use crate::store::{Access, Lease, Opened, Store, StoreError};

/// The result of a call that was open when its turn stopped. The model reads it.
const OUTCOME_UNKNOWN: &str = "The turn stopped before it saved the result of this call. The call can have run.";

/// The failure of a turn that stopped before it saved its end.
const TURN_STOPPED: &str = "the turn stopped before it saved its end";

/// A session that one writer owns. Each turn runs on the context of the session. The session saves each commit of
/// the turn in its store before the turn goes on.
pub struct Session {
    settings: SessionSettings,
    context: Vec<yuke_ai::Block>,
    journal: SessionJournal,
    /// `None` after a failed or dropped turn, until the next turn opens the session again.
    lease: Option<Lease>,
}

impl fmt::Debug for Session {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Session")
            .field("id", &self.journal.id)
            .field("settings", &self.settings)
            .field("context", &self.context)
            .finish_non_exhaustive()
    }
}

/// The journal, the inbox, and the blob store of the turns of a session. It saves each commit in the store of the
/// session, and it reads the blobs of the session from the store.
struct SessionJournal {
    store: Arc<dyn Store>,
    id: SessionId,
    inputs: Mutex<Inputs>,
}

#[derive(Default)]
struct Inputs {
    /// The pending inputs of the store that no turn took, as the newest load gave them.
    waiting: Vec<PendingInput>,
    /// The ids of the inputs that a turn took and that no saved commit consumed.
    taken: Vec<InputId>,
}

impl SessionJournal {
    /// Load the pending inputs of the store as the waiting inputs.
    async fn load_pending(&self) -> Result<(), StoreError> {
        let pending = self.store.pending(self.id).await?;
        lock(&self.inputs).waiting = pending;
        Ok(())
    }

    /// Move each waiting input to the taken inputs, and return their blocks in input order.
    fn take_waiting(&self) -> Vec<yuke_ai::Block> {
        let mut inputs = lock(&self.inputs);
        let waiting = std::mem::take(&mut inputs.waiting);
        inputs.taken.extend(waiting.iter().map(|input| input.id));
        waiting.into_iter().flat_map(|input| input.blocks).collect()
    }
}

#[async_trait]
impl Journal for SessionJournal {
    async fn commit(&self, commit: &Commit<'_>) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // The first commit after a take holds the blocks of the taken inputs, so it consumes their ids. The ids leave
        // `taken` before the save: after a failed save, the next turn takes the inputs that are still pending again.
        let consumed = std::mem::take(&mut lock(&self.inputs).taken);
        self.store.commit(self.id, commit, &consumed).await?;
        // The inbox then gives the input that arrived during the round.
        self.load_pending().await?;
        Ok(())
    }
}

impl Inbox for SessionJournal {
    fn take(&self) -> Vec<yuke_ai::Block> {
        self.take_waiting()
    }
}

impl yuke_ai::BlobStore for SessionJournal {
    fn read(
        &self,
        digest: &yuke_ai::Digest,
    ) -> Result<Option<std::borrow::Cow<'_, [u8]>>, Box<dyn std::error::Error + Send + Sync>> {
        Ok(self.store.read_blob(self.id, digest)?.map(std::borrow::Cow::Owned))
    }
}

impl Session {
    /// Create a session with `settings` in `store`, and own it.
    ///
    /// # Errors
    ///
    /// Returns the error of [`Store::create_session`].
    pub async fn create(store: Arc<dyn Store>, settings: SessionSettings) -> Result<Session, StoreError> {
        let opened = store.create_session(&settings).await?;
        Ok(Session::from_opened(store, opened))
    }

    /// Open session `id` of `store`, and own it. A turn that was open when its process stopped ends as
    /// [`TurnEnd::Failed`], and each call without a result gets an error result. The session starts no turn, so the
    /// pending inputs wait for [`Session::turn`].
    ///
    /// # Errors
    ///
    /// Returns the error of [`Store::open`], or of the commit that ends an open turn.
    pub async fn open(store: Arc<dyn Store>, id: SessionId) -> Result<Session, StoreError> {
        let opened = open_for_writing(&*store, id).await?;
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
            context: opened.context,
            journal: SessionJournal {
                store,
                id: opened.id,
                inputs: Mutex::default(),
            },
            lease: opened.lease,
        }
    }

    /// The id of the session.
    pub fn id(&self) -> SessionId {
        self.journal.id
    }

    /// The current settings.
    pub fn settings(&self) -> &SessionSettings {
        &self.settings
    }

    /// The context. After a failed or dropped turn, it can hold blocks that the store lacks. The next turn then loads
    /// the context from the store.
    pub fn context(&self) -> &[yuke_ai::Block] {
        &self.context
    }

    /// Save `settings` as the current settings. After a failed or dropped turn, the session first opens again, so
    /// only the owner writes.
    ///
    /// # Errors
    ///
    /// Returns the error of [`Store::open`] when the session cannot open again, for example [`StoreError::Owned`].
    /// Returns the error of [`Store::set_settings`] otherwise.
    pub async fn set_settings(&mut self, settings: SessionSettings) -> Result<(), StoreError> {
        if self.lease.is_none() {
            self.reopen().await?;
        }
        // The store can save after the caller drops this future. So the future holds the lease, and a dropped write
        // makes the next turn open the session again from the store.
        let lease = self.lease.take();
        self.journal.store.set_settings(self.journal.id, &settings).await?;
        self.settings = settings;
        self.lease = lease;
        Ok(())
    }

    /// A sender of input. Another task can send input while a turn runs.
    pub fn input(&self) -> InputSender {
        InputSender {
            store: Arc::clone(&self.journal.store),
            id: self.journal.id,
        }
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
        }
    }

    /// Open the session again after a failed or dropped turn. The store holds the truth about the context and the
    /// pending inputs.
    async fn reopen(&mut self) -> Result<(), StoreError> {
        let opened = open_for_writing(&*self.journal.store, self.journal.id).await?;
        self.settings = opened.settings;
        self.context = opened.context;
        self.lease = opened.lease;
        Ok(())
    }
}

/// Open session `id` for writing, and end a turn that was open when its process stopped.
async fn open_for_writing(store: &dyn Store, id: SessionId) -> Result<Opened, StoreError> {
    let opened = store.open(id, Access::Write).await?;
    end_open_turn(store, opened).await
}

/// End the open turn of `opened`: each call without a result gets an error result, and the turn ends as failed.
async fn end_open_turn(store: &dyn Store, mut opened: Opened) -> Result<Opened, StoreError> {
    if opened.turn_open {
        let results = open_calls(&opened.context)
            .map(|call_id| yuke_ai::Block::ToolResult(yuke_ai::ToolResult::error(call_id, OUTCOME_UNKNOWN)))
            .collect::<Vec<_>>();
        let repair = Commit {
            replaced: None,
            blocks: std::borrow::Cow::Borrowed(&results),
            answer: None,
            end: Some(TurnEnd::Failed(TURN_STOPPED.to_owned())),
        };
        store.commit(opened.id, &repair, &[]).await?;
        opened.context.extend(results);
        opened.turn_open = false;
    }
    Ok(opened)
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

/// Sends input to a session. The input is pending in the store before [`InputSender::send`] returns.
#[derive(Clone)]
pub struct InputSender {
    store: Arc<dyn Store>,
    id: SessionId,
}

impl fmt::Debug for InputSender {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("InputSender")
            .field("session", &self.id)
            .finish_non_exhaustive()
    }
}

impl InputSender {
    /// Save `blocks` as a pending input. A turn that runs takes it after its next commit. The next turn takes it
    /// otherwise.
    ///
    /// # Errors
    ///
    /// Returns the error of [`Store::accept_input`].
    pub async fn send(&self, blocks: &[yuke_ai::Block]) -> Result<InputId, StoreError> {
        self.store.accept_input(self.id, blocks).await
    }
}

/// One turn of a session. It does nothing until [`SessionTurn::run`].
#[must_use = "a turn does nothing until the caller runs it"]
pub struct SessionTurn<'s> {
    session: &'s mut Session,
    driver: Driver<'s>,
    observer: Option<&'s dyn Observer>,
    cancellation_token: CancellationToken,
}

impl fmt::Debug for SessionTurn<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionTurn")
            .field("session", &self.session.journal.id)
            .field("driver", &self.driver)
            .finish_non_exhaustive()
    }
}

impl<'s> SessionTurn<'s> {
    /// Give each event of the turn to `observer`.
    pub fn observer(self, observer: &'s dyn Observer) -> Self {
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

    /// Run the turn until it ends. After a failed commit, or when the caller drops this future, the session drops its
    /// lease. The next turn then opens the session again from the store.
    ///
    /// # Errors
    ///
    /// Returns [`SessionError::Model`] when a request fails. Returns [`SessionError::Store`] when the store fails,
    /// also when the session cannot open again.
    pub async fn run(self) -> Result<Outcome, SessionError> {
        let SessionTurn {
            session,
            driver,
            observer,
            cancellation_token,
        } = self;
        if session.lease.is_none() {
            session.reopen().await?;
        }
        session.journal.load_pending().await?;
        // The future holds the lease while the turn runs, so a dropped future releases it.
        let lease = session.lease.take();
        let input = session.journal.take_waiting();
        let session_id = session.journal.id.to_string();
        let journal: &SessionJournal = &session.journal;
        let mut turn = driver
            .settings(&session.settings.settings)
            .session_id(&session_id)
            .journal(journal)
            .inbox(journal)
            .blobs(journal)
            .turn(&mut session.context, input)
            .cancellation_token(cancellation_token);
        if let Some(observer) = observer {
            turn = turn.observer(observer);
        }
        match turn.run().await {
            Ok(outcome) => {
                session.lease = lease;
                Ok(outcome)
            }
            Err(TurnError::Model(error)) => {
                session.lease = lease;
                Err(SessionError::Model(error))
            }
            // The commit can have saved or not, so the lease drops, and the next turn loads the store.
            Err(TurnError::Commit(error)) => Err(SessionError::Store(match error.downcast::<StoreError>() {
                Ok(error) => *error,
                Err(error) => StoreError::Failed(error),
            })),
        }
    }
}

/// Why a turn of a session failed.
#[derive(Debug)]
pub enum SessionError {
    /// A request could not be encoded, or its last attempt failed. The store holds the end of the turn.
    Model(yuke_ai::Error),
    /// The store failed.
    Store(StoreError),
}

impl From<StoreError> for SessionError {
    fn from(error: StoreError) -> Self {
        Self::Store(error)
    }
}

impl fmt::Display for SessionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Model(error) => fmt::Display::fmt(error, f),
            Self::Store(error) => fmt::Display::fmt(error, f),
        }
    }
}

impl std::error::Error for SessionError {
    // The text is the text of the inner error, so the source is the source of the inner error.
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Model(error) => error.source(),
            Self::Store(error) => error.source(),
        }
    }
}
