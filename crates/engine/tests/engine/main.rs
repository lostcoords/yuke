//! Behavior tests of the engine. One binary links once, so the suite stays fast.
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "a test fails by panicking"
)]

mod after_tool;
mod after_turn;
mod before_round;
mod conversation;
mod deferred;
mod drive;
mod support;
mod tool_api;
