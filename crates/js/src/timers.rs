//! The timer globals `setTimeout`, `setInterval`, `clearTimeout`, and `clearInterval`. One future fires the due
//! timers by due time, then by id, so timers with one due time fire in the order of their set.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Duration;

use rquickjs::function::{Opt, Rest};
use rquickjs::{Coerced, Ctx, FromJs, Function, Persistent, Value};
use tokio::sync::{Notify, mpsc};
use tokio::time::Instant;

use crate::error::{Error, Report, caught};

/// The longest delay. A longer delay counts as this one, as the web timers do.
const LONGEST_DELAY: f64 = i32::MAX as f64;

/// The timers of one runtime.
#[derive(Debug, Default)]
pub(crate) struct Timers {
    state: RefCell<State>,
    changed: Notify,
}

#[derive(Debug, Default)]
struct State {
    last_id: u64,
    /// The waiting timers by id. A script holds few timers, so a search by due time reads each one.
    waiting: BTreeMap<u64, Timer>,
    /// The timer whose callback runs now. A clear in the callback takes it, so the timer does not come back.
    firing: Option<u64>,
}

#[derive(Debug)]
struct Timer {
    due: Instant,
    callback: Persistent<Function<'static>>,
    arguments: Vec<Persistent<Value<'static>>>,
    interval: Option<Duration>,
}

impl Timers {
    /// Drop each waiting timer. The runtime must outlive each saved value, so the thread calls this before it drops
    /// the runtime.
    pub(crate) fn clear(&self) {
        self.state.borrow_mut().waiting.clear();
    }

    fn set<'js>(
        &self,
        ctx: &Ctx<'js>,
        callback: Function<'js>,
        delay: Opt<Value<'js>>,
        arguments: Rest<Value<'js>>,
        repeat: bool,
    ) -> rquickjs::Result<f64> {
        let delay = delay_of(ctx, delay.0)?;
        let mut state = self.state.borrow_mut();
        state.last_id += 1;
        let id = state.last_id;
        let timer = Timer {
            due: Instant::now() + delay,
            callback: Persistent::save(ctx, callback),
            arguments: arguments
                .0
                .into_iter()
                .map(|argument| Persistent::save(ctx, argument))
                .collect(),
            interval: repeat.then_some(delay),
        };
        state.waiting.insert(id, timer);
        drop(state);
        self.changed.notify_one();
        #[expect(clippy::cast_precision_loss, reason = "a script cannot set 2^53 timers")]
        Ok(id as f64)
    }

    fn clear_id(&self, id: u64) {
        let mut state = self.state.borrow_mut();
        if state.waiting.remove(&id).is_none() && state.firing == Some(id) {
            state.firing = None;
        }
    }

    /// The ids of the timers due at `now`, by due time, then by id. A timer that a callback sets waits for the next
    /// round.
    fn due_ids(&self, now: Instant) -> Vec<u64> {
        let state = self.state.borrow();
        let mut due: Vec<(Instant, u64)> = state
            .waiting
            .iter()
            .filter(|(_, timer)| timer.due <= now)
            .map(|(id, timer)| (timer.due, *id))
            .collect();
        due.sort_unstable();
        due.into_iter().map(|(_, id)| id).collect()
    }

    /// Take the timer `id` out of the waiting timers to fire it. A callback of this round can have cleared it.
    fn start(&self, id: u64) -> Option<Timer> {
        let mut state = self.state.borrow_mut();
        let timer = state.waiting.remove(&id)?;
        state.firing = Some(id);
        Some(timer)
    }

    /// Put an interval back with a due time from now, unless its own callback cleared it.
    fn finish(&self, id: u64, mut timer: Timer) {
        let mut state = self.state.borrow_mut();
        let firing = state.firing.take();
        if let Some(interval) = timer.interval
            && firing == Some(id)
        {
            timer.due = Instant::now() + interval;
            state.waiting.insert(id, timer);
        }
    }

    fn next_due(&self) -> Option<Instant> {
        self.state.borrow().waiting.values().map(|timer| timer.due).min()
    }
}

/// Convert a delay as the web timers do: a missing, non-finite, or negative delay is zero, and a fraction rounds down.
fn delay_of<'js>(ctx: &Ctx<'js>, delay: Option<Value<'js>>) -> rquickjs::Result<Duration> {
    let milliseconds = match delay {
        Some(value) if !value.is_undefined() => Coerced::<f64>::from_js(ctx, value)?.0,
        _ => 0.0,
    };
    if !milliseconds.is_finite() || milliseconds <= 0.0 {
        return Ok(Duration::ZERO);
    }
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the value is in 0..=2^31-1"
    )]
    let milliseconds = milliseconds.min(LONGEST_DELAY).floor() as u64;
    Ok(Duration::from_millis(milliseconds))
}

/// The id of a `clearTimeout` argument. A value that is no timer id clears nothing.
fn id_of(value: Option<Value<'_>>) -> Option<u64> {
    let number = value?.as_number()?;
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "the value is a whole number ≥ 1"
    )]
    (number >= 1.0 && number.fract() == 0.0 && number <= 2f64.powi(53)).then_some(number as u64)
}

/// Add the timer globals to `ctx`, and start the future that fires the timers. A throw of a callback goes to
/// `faults`.
pub(crate) fn install<'js>(
    ctx: &Ctx<'js>,
    timers: &Rc<Timers>,
    faults: mpsc::UnboundedSender<Report>,
) -> rquickjs::Result<()> {
    let globals = ctx.globals();

    for (name, repeat) in [("setTimeout", false), ("setInterval", true)] {
        let set_timers = Rc::clone(timers);
        globals.set(
            name,
            Function::new(
                ctx.clone(),
                move |ctx: Ctx<'js>, callback: Function<'js>, delay: Opt<Value<'js>>, arguments: Rest<Value<'js>>| {
                    set_timers.set(&ctx, callback, delay, arguments, repeat)
                },
            )?,
        )?;
    }

    // One id space holds timeouts and intervals, so one function clears both.
    let clear_timers = Rc::clone(timers);
    let clear = Function::new(ctx.clone(), move |id: Opt<Value<'js>>| {
        if let Some(id) = id_of(id.0) {
            clear_timers.clear_id(id);
        }
    })?;
    globals.set("clearTimeout", clear.clone())?;
    globals.set("clearInterval", clear)?;

    ctx.spawn(fire(ctx.clone(), Rc::clone(timers), faults));
    Ok(())
}

/// Fire each timer at its due time, for as long as the runtime lives.
async fn fire(ctx: Ctx<'_>, timers: Rc<Timers>, faults: mpsc::UnboundedSender<Report>) {
    loop {
        let Some(due) = timers.next_due() else {
            timers.changed.notified().await;
            continue;
        };
        tokio::select! {
            () = tokio::time::sleep_until(due) => {}
            () = timers.changed.notified() => continue,
        }

        for id in timers.due_ids(Instant::now()) {
            let Some(timer) = timers.start(id) else { continue };
            // The main loop reports each interrupt once, so a callback reports only its throw.
            if let Err(Error::Script(error)) = call(&ctx, &timer)
                && faults.send(Report::Fault(error)).is_err()
            {
                // The owner dropped the receiver, so it ignores faults.
            }
            // The promise reactions of a callback run before the next callback, as on the web.
            while ctx.execute_pending_job() {}
            timers.finish(id, timer);
        }

        // A timer with no delay that sets itself again must let other work run.
        tokio::task::yield_now().await;
    }
}

fn call(ctx: &Ctx<'_>, timer: &Timer) -> Result<(), Error> {
    let callback = caught(ctx, timer.callback.clone().restore(ctx))?;
    let arguments = timer
        .arguments
        .iter()
        .map(|argument| caught(ctx, argument.clone().restore(ctx)))
        .collect::<Result<Vec<_>, _>>()?;
    caught(ctx, callback.call::<_, ()>((Rest(arguments),)))
}
