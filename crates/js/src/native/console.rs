//! The console function of the native module: `writeConsole` sends an entry of `console` as a report.

use rquickjs::{Ctx, Function, Object};
use tokio::sync::mpsc;

use crate::error::{ErrorClass, Report, throw};

/// Add `writeConsole(level, text)` to `object`, the export object of the native module.
pub(super) fn add<'js>(
    ctx: &Ctx<'js>,
    object: &Object<'js>,
    reports: mpsc::UnboundedSender<Report>,
) -> rquickjs::Result<()> {
    object.set(
        "writeConsole",
        Function::new(ctx.clone(), move |ctx: Ctx<'js>, level: String, text: String| {
            let Some(level) = super::notice_level(&level) else {
                return Err(throw(
                    &ctx,
                    ErrorClass::TypeError,
                    &format!("'{level}' is not a console level"),
                ));
            };
            if reports.send(Report::Console { level, text }).is_err() {
                // The owner dropped the receiver, so it ignores the console.
            }
            Ok(())
        })?,
    )
}
