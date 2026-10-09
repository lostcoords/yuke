//! Behavior tests of the engine. One binary links once, so the suite stays fast.
#![expect(clippy::unwrap_used, clippy::expect_used, reason = "a test fails by panicking")]

mod after_round;
mod after_tool;
mod before_round;
mod deferred;
mod drive;
mod parallel;
mod support;
mod tool_api;
