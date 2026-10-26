//! The core of the terminal interface on a fake driver: placement, clipping, input routing, focus, overlays, panes,
//! and the fault boundary.

use std::time::Duration;

use rquickjs::{Ctx, Module, Object};

use super::{evaluate, folder, start};
use crate::Runtime;
use crate::error::caught;

/// A runtime with a `Core` on a fake 20×6 driver, and the helpers of the tests on the global object:
/// - `core`, `stack`, `frames` (asks for a frame), `calls` (quit, suspend, reload), `cursorAt`;
/// - `screen()` draws a frame and gives its rows, trimmed at the end;
/// - `press(character, mods)`, `named(code)`, `click(column, row, action, button)` send events;
/// - `atoms()` gives the keymap atoms; `log` collects what the test views record.
async fn scene(name: &str) -> Runtime {
    let (runtime, _reports) = start(&folder(name)).await;
    runtime
        .caller
        .run(async move |ctx: Ctx<'_>, _registry| {
            for module in ["yuke:internal/tui/core", "yuke:tui"] {
                let promise = caught(&ctx, Module::import(&ctx, module))?;
                let namespace = caught(&ctx, promise.into_future::<Object<'_>>().await)?;
                for key in namespace.keys::<String>() {
                    let key = caught(&ctx, key)?;
                    let value = caught(&ctx, namespace.get::<_, rquickjs::Value<'_>>(&key))?;
                    caught(&ctx, ctx.globals().set(key, value))?;
                }
            }
            Ok(())
        })
        .await
        .unwrap();
    evaluate::<()>(
        &runtime,
        "const W = 20, H = 6;
         const grid = Array.from({ length: H }, () => Array(W).fill(' '));
         globalThis.frames = 0;
         globalThis.calls = [];
         globalThis.log = [];
         globalThis.cursorAt = undefined;
         const put = (column, row, character) => {
           if (row >= 0 && row < H && column >= 0 && column < W) grid[row][column] = character;
         };
         const driver = {
           width: () => W, height: () => H, background: () => 'dark', truecolor: () => true,
           text: (column, row, text) => { [...text].forEach((character, at) => put(column + at, row, character)); },
           fill: (column, row, width, height) => {
             for (let r = row; r < row + height; r += 1) for (let c = column; c < column + width; c += 1) put(c, r, ' ');
           },
           cursor: (point) => { cursorAt = point === undefined ? 'none' : `${point.column},${point.row}`; },
           requestFrame: () => { frames += 1; },
           quit: () => calls.push('quit'), suspend: () => calls.push('suspend'), reload: () => calls.push('reload'),
         };
         globalThis.core = new Core(driver, () => ({ draw: (canvas) => { canvas.text(0, 0, 'empty'); } }));
         globalThis.screen = () => {
           for (const row of grid) row.fill(' ');
           core.draw();
           return grid.map((row) => row.join('').trimEnd());
         };
         const none = { shift: false, alt: false, ctrl: false, super: false, hyper: false, meta: false };
         globalThis.press = (character, mods = 0) => core.event({ type: 'key', code: 'character', character,
           shifted: '', baseLayout: '', text: character, modifiers: { ...none, ctrl: (mods & 4) !== 0 } });
         globalThis.named = (code) =>
           core.event({ type: 'key', code, character: '', shifted: '', baseLayout: '', text: '', modifiers: none });
         globalThis.click = (column, row, action = 'press', button = 'left') =>
           core.event({ type: 'mouse', column, row, button, action, modifiers: none });
         globalThis.atoms = () => { core.scene.layout(); return core.scene.atoms().join(' '); };",
    )
    .await
    .unwrap();
    runtime
}

async fn text(runtime: &Runtime, body: &str) -> String {
    evaluate::<String>(runtime, body).await.unwrap()
}

#[tokio::test]
async fn a_placed_child_draws_in_its_rect_and_is_cut_to_it() {
    let runtime = scene("a_placed_child_draws_in_its_rect_and_is_cut_to_it").await;
    let rows = text(
        &runtime,
        "const left = { draw: (canvas) => { canvas.text(0, 0, 'abcdefgh'); canvas.text(1, 1, 'xyz');
           canvas.text(0, 2, 'below'); canvas.fill(0, 3, 4, 1); } };
         const right = { draw: (canvas) => { canvas.fill(0, 0, canvas.width, canvas.height);
           canvas.text(-2, 0, 'ABCDE'); canvas.region(1, 1, 2, 1).text(0, 0, 'QRS');
           canvas.text(-1, 2, '中Z'); } };
         core.scene.setRoot('test', () => ({
           layout: () => [
             { view: left, rect: { column: 0, row: 0, width: 4, height: 2 } },
             { view: right, rect: { column: 5, row: 0, width: 4, height: 3 } },
           ],
           draw: (canvas) => { canvas.text(0, 3, 'parent'); },
         }));
         return screen().slice(0, 4).join('|');",
    )
    .await;
    // `abcdefgh` stops at the width 4 of its rect; `ABCDE` at column -2 loses `AB`; the region keeps `QR`.
    // The wide `中` across the left edge leaves its visible cell blank before `Z`.
    assert_eq!(rows, "abcd CDE| xyz  QR|      Z|parent");
}

#[tokio::test]
async fn a_stack_gives_sized_children_their_cells_and_fill_the_rest() {
    let runtime = scene("a_stack_gives_sized_children_their_cells").await;
    let rects = text(
        &runtime,
        "const views = [0, 1, 2, 3].map(() => ({ draw() {} }));
         const layout = stack('column', [
           { view: views[0], size: 1 },
           { view: views[1], size: 'fill' },
           { view: views[2], size: (size) => Math.floor(size.width / 10) },
           { view: views[3], size: 'fill' },
         ]).layout({ width: 20, height: 10 });
         const row = stack('row', [{ view: views[0], size: 30 }, { view: views[1], size: 'fill' }])
           .layout({ width: 20, height: 3 });
         return [...layout, ...row].map(({ rect }) => `${rect.column},${rect.row},${rect.width},${rect.height}`).join(' ');",
    )
    .await;
    // Column: 1 row, then 2 rows from the function, then 7 rows shared by the fills (3 and the rest, 4).
    assert_eq!(rects, "0,0,20,1 0,1,20,3 0,4,20,2 0,6,20,4 0,0,20,3 20,0,0,3");
}

#[tokio::test]
async fn a_key_goes_to_the_keymap_first_then_up_the_focus_path() {
    let runtime = scene("a_key_goes_to_the_keymap_first").await;
    let order = text(
        &runtime,
        "core.commands.add({ name: 'test:bound', run: () => { log.push('command'); } });
         core.keymap.bind('b', 'test:bound');
         const child = { focusable: true, contexts: ['editor'], draw() {},
           key: (event) => { log.push(`child ${event.character}`); return event.character === 'c'; } };
         core.scene.setRoot('test', () => ({
           layout: () => [{ view: child, rect: { column: 0, row: 0, width: 5, height: 1 } }],
           draw() {}, key: (event) => { log.push(`parent ${event.character}`); return true; },
         }));
         core.scene.layout();
         core.scene.focus(child);
         press('b'); press('c'); press('p');
         return `${log.join(', ')} | ${atoms()}`;",
    )
    .await;
    assert_eq!(order, "command, child c, child p, parent p | global root editor");
}

#[tokio::test]
async fn escape_closes_the_top_modal_when_nothing_takes_it() {
    let runtime = scene("escape_closes_the_top_modal").await;
    let steps = text(
        &runtime,
        "let query = 'abc';
         const keeps = core.scene.overlay('test', (mount) => {
           mount.signal.addEventListener('abort', () => log.push('keeps closed'));
           return { draw() {}, key: (event) => {
             if (event.code === 'esc' && query !== '') { query = ''; return true; }
             return false;
           } };
         });
         named('esc');
         const after = keeps.signal.aborted;
         named('esc');
         core.scene.overlay('test', () => ({ draw() {} }), { modal: false });
         named('esc');
         return [after, keeps.signal.aborted, log.join(' '), atoms()].join(' | ');",
    )
    .await;
    // The first Escape clears the query; the second closes the modal; a float stays open.
    assert_eq!(steps, "false | true | keeps closed | global root");
}

#[tokio::test]
async fn a_modal_takes_all_input_below_it_and_a_float_takes_only_what_it_handles() {
    let runtime = scene("a_modal_takes_all_input_below_it").await;
    let steps = text(
        &runtime,
        "core.scene.setRoot('test', () => ({ focusable: true, draw() {},
           key: () => { log.push('root key'); return true; },
           mouse: (event) => { log.push(`root mouse ${event.action}`); return true; } }));
         const float = core.scene.overlay('test', () => ({ draw() {},
           key: (event) => { log.push('float key'); return event.character === 'f'; },
           mouse: () => { log.push('float mouse'); return true; } }),
           { modal: false, place: () => ({ column: 0, row: 0, width: 3, height: 1 }) });
         press('f'); press('x'); click(1, 0); click(10, 3);
         const before = log.splice(0).join(', ');
         float.close();
         const modal = core.scene.overlay('test', () => ({ draw() {}, key: () => false, mouse: () => false }));
         press('x'); click(10, 3);
         return `${before} | ${log.join(', ')} | ${atoms()}`;",
    )
    .await;
    assert_eq!(
        steps,
        "float key, float key, root key, float mouse, root mouse press | root mouse cancel | global overlay"
    );
}

#[tokio::test]
async fn a_press_focuses_and_captures_and_a_modal_cancels_the_capture() {
    let runtime = scene("a_press_focuses_and_captures").await;
    let steps = text(
        &runtime,
        "const record = (name) => (event) => { log.push(`${name} ${event.action} ${event.column},${event.row}`); return true; };
         const a = { focusable: true, draw() {}, mouse: record('a') };
         const b = { focusable: true, draw() {}, mouse: record('b') };
         core.scene.setRoot('test', () => ({
           layout: () => [
             { view: a, rect: { column: 0, row: 0, width: 5, height: 2 } },
             { view: b, rect: { column: 10, row: 0, width: 5, height: 2 } },
           ],
           draw() {},
         }));
         click(11, 1);
         const focusedB = core.scene.focused === b;
         click(2, 0, 'press');
         click(15, 4, 'drag');
         click(16, 5, 'release');
         click(1, 1, 'press');
         core.scene.overlay('test', () => ({ draw() {} }));
         click(3, 3, 'release');
         return `${focusedB} ${core.scene.focused === a} | ${log.join(', ')}`;",
    )
    .await;
    // The drag and the release reach `a` outside its rect; the modal sends `cancel` and takes the later release.
    assert_eq!(
        steps,
        "true false | b press 1,1, a press 2,0, a drag 15,4, a release 16,5, a press 1,1, a cancel 1,1"
    );
}

#[tokio::test]
async fn panes_split_focus_and_close_and_the_last_pane_stays() {
    let runtime = scene("panes_split_focus_and_close").await;
    let steps = text(
        &runtime,
        "const pane = (name) => (mount) => ({ draw: (canvas, focused) => { canvas.text(0, 0, focused ? name.toUpperCase() : name); } });
         const panes = core.panes.facade('test');
         const a = panes.split(pane('a'));
         const b = panes.split(pane('b'), { direction: 'column' });
         const shown = [screen().join('|')];
         core.commands.run('core:focus-left');
         shown.push(screen()[0]);
         core.commands.run('core:focus-right');
         b.close();
         shown.push(screen().slice(0, 3).join('|'), String(panes.active === a));
         core.commands.run('core:close');
         core.commands.run('core:close');
         shown.push(screen()[0], String(panes.active), String(a.signal.aborted));
         // A plugin pane as the last pane gives way to a placeholder too.
         const c = panes.split(pane('c'));
         // Focus by direction reads the rects of the last layout, which each key runs first.
         screen();
         core.commands.run('core:focus-left');
         core.commands.run('core:close');
         const alone = screen()[0];
         c.close();
         shown.push(alone, screen()[0]);
         return shown.join(' / ');",
    )
    .await;
    // The first split puts `a` right of the placeholder, the second puts `b` below `a`. A close goes back to `a`; the
    // close of `a` leaves the placeholder; the close of the last pane keeps a placeholder.
    assert_eq!(
        steps,
        "empty     │a|          │|          │|          │─────────|          │B|          │ / empty     │a / empty     │A|          │|          │ / true / empty / undefined / true / C / empty"
    );
}

#[tokio::test]
async fn a_pane_gets_its_inner_focus_back_and_focus_changes_reach_the_path() {
    let runtime = scene("a_pane_gets_its_inner_focus_back").await;
    let steps = text(
        &runtime,
        "const composer = { focusable: true, draw() {}, focusChanged: (focused) => log.push(`composer ${focused}`) };
         const transcript = { focusable: true, draw() {} };
         const chat = { draw() {}, focusChanged: (focused) => log.push(`chat ${focused}`),
           layout: (size) => [
             { view: transcript, rect: { column: 0, row: 0, width: size.width, height: size.height - 1 } },
             { view: composer, rect: { column: 0, row: size.height - 1, width: size.width, height: 1 } },
           ] };
         const panes = core.panes.facade('test');
         panes.split(() => chat);
         core.scene.layout();
         core.scene.focus(composer);
         core.commands.add({ name: 'test:none', run() {} });
         core.keymap.bind('ctrl+k x', 'test:none');
         core.commands.run('core:focus-left');
         core.scene.layout();
         press('k', 4);
         const pending = core.keymap.pending();
         core.commands.run('core:focus-right');
         core.scene.layout();
         return `${core.scene.focused === composer} ${pending} [${core.keymap.pending()}] | ${log.join(', ')}`;",
    )
    .await;
    // Back in the chat pane the composer has the focus again; the focus change drops the pending `ctrl+k`.
    assert_eq!(
        steps,
        "true ctrl+k [] | chat true, composer true, chat false, composer false, chat true, composer true"
    );
}

#[tokio::test]
async fn a_throwing_view_shows_its_error_once_and_the_rest_works() {
    let runtime = scene("a_throwing_view_shows_its_error_once").await;
    let steps = text(
        &runtime,
        "let draws = 0;
         const broken = { focusable: true, draw: () => { draws += 1; throw new Error('bad view'); },
           key: () => { throw new Error('bad key'); } };
         const fine = { draw: (canvas) => { canvas.text(0, 0, 'fine'); } };
         core.scene.setRoot('notes', () => ({
           layout: () => [
             { view: broken, rect: { column: 0, row: 0, width: 20, height: 1 } },
             { view: fine, rect: { column: 0, row: 1, width: 20, height: 1 } },
           ],
           draw() {},
         }));
         const first = screen().slice(0, 2).join('|');
         screen();
         // A failed view gets no more calls: its keys give no second fault.
         core.scene.focus(broken);
         press('x'); press('y');
         const failed = core.scene.overlay('notes', () => { throw new Error('no view'); });
         const faults = core.notices.list().map((notice) => `${notice.source}: ${notice.text.split('\\n')[0]}`);
         return `${first} | ${draws} | ${failed.signal.aborted} | ${faults.join(' / ')}`;",
    )
    .await;
    assert_eq!(
        steps,
        "notes: Error: bad vi|fine | 1 | true | notes: Error: bad view / notes: a view did not start: Error: no view"
    );
}

#[tokio::test]
async fn a_new_root_closes_the_old_one_and_its_close_gives_the_default_root_back() {
    let runtime = scene("a_new_root_closes_the_old_one").await;
    let steps = text(
        &runtime,
        "const first = core.scene.setRoot('test', () => ({ draw: (canvas) => { canvas.text(0, 0, 'first'); } }));
         const second = core.scene.setRoot('test', () => ({ draw: (canvas) => { canvas.text(0, 0, 'second'); } }));
         const shown = [first.signal.aborted, screen()[0]];
         first.close();
         shown.push(screen()[0]);
         second.close();
         shown.push(screen()[0], second.signal.aborted);
         return shown.join(' ');",
    )
    .await;
    // The close of an old root changes nothing; the close of the current root shows the pane tree again.
    assert_eq!(steps, "true second second empty true");
}

#[tokio::test]
async fn the_cursor_of_the_focused_view_reaches_the_screen_inside_its_clip() {
    let runtime = scene("the_cursor_of_the_focused_view").await;
    let steps = text(
        &runtime,
        "let at = { column: 2, row: 0 };
         const input = { focusable: true, draw() {}, cursor: () => at };
         core.scene.setRoot('test', () => ({
           layout: () => [{ view: input, rect: { column: 5, row: 3, width: 4, height: 1 } }], draw() {},
         }));
         core.scene.layout();
         core.scene.focus(input);
         screen();
         const inside = cursorAt;
         at = { column: 9, row: 0 };
         screen();
         return `${inside} ${cursorAt}`;",
    )
    .await;
    assert_eq!(steps, "7,3 none");
}

#[tokio::test]
async fn the_core_commands_reach_the_driver() {
    let runtime = scene("the_core_commands_reach_the_driver").await;
    let steps = text(
        &runtime,
        "for (const name of ['quit', 'suspend', 'reload']) core.commands.run(`core:${name}`);
         return calls.join(' ');",
    )
    .await;
    assert_eq!(steps, "quit suspend reload");
    tokio::time::sleep(Duration::from_millis(1)).await;
}

#[tokio::test]
async fn a_factory_that_closes_its_own_mount_mounts_nothing() {
    let runtime = scene("a_factory_that_closes_its_own_mount").await;
    let steps = text(
        &runtime,
        "const root = core.scene.setRoot('test', (mount) => {
           mount.close();
           return { draw: (canvas) => { canvas.text(0, 0, 'closed'); } };
         });
         const overlay = core.scene.overlay('test', (mount) => { mount.close(); return { draw() {} }; });
         const pane = core.panes.facade('test').split((mount) => { mount.close(); return { draw() {} }; });
         return `${screen()[0]} ${root.signal.aborted} ${overlay.signal.aborted} ${pane.signal.aborted} ${atoms()}`;",
    )
    .await;
    assert_eq!(steps, "empty true true true global root");
}

#[tokio::test]
async fn a_focus_change_beneath_a_modal_moves_the_active_pane() {
    let runtime = scene("a_focus_change_beneath_a_modal").await;
    let steps = text(
        &runtime,
        "const panes = core.panes.facade('test');
         const a = panes.split(() => ({ draw() {} }));
         const b = panes.split(() => ({ draw() {} }));
         screen();
         core.scene.overlay('test', () => ({ draw() {} }));
         screen();
         // A focus of the scene beneath the modal, as `tui.focus` gives, moves the active pane too.
         core.scene.focus(a.view);
         screen();
         return `${panes.active === a} ${atoms()}`;",
    )
    .await;
    assert_eq!(steps, "true global overlay");
}

#[tokio::test]
async fn a_view_that_leaves_the_tree_gets_its_focus_loss_and_its_capture_cancel() {
    let runtime = scene("a_view_that_leaves_the_tree").await;
    let steps = text(
        &runtime,
        "let shown = true;
         const child = { focusable: true, draw() {},
           focusChanged: (focused) => log.push(`focus ${focused}`),
           mouse: (event) => { log.push(`mouse ${event.action}`); return true; } };
         core.scene.setRoot('test', () => ({
           layout: () => shown ? [{ view: child, rect: { column: 0, row: 0, width: 5, height: 1 } }] : [],
           draw() {},
         }));
         click(1, 0, 'press');
         shown = false;
         screen();
         const atLayout = log.join(', ');
         click(2, 0, 'release');
         return `${atLayout} | ${log.length}`;",
    )
    .await;
    // The child leaves the layout during its drag: the layout gives it `cancel` and `focus false`; the release is gone.
    assert_eq!(steps, "focus true, mouse press, mouse cancel, focus false | 4");
}

#[tokio::test]
async fn a_press_that_opens_a_modal_captures_nothing() {
    let runtime = scene("a_press_that_opens_a_modal").await;
    let steps = text(
        &runtime,
        "const opener = { focusable: true, draw() {}, mouse: (event) => {
           log.push(`opener ${event.action}`);
           if (event.action === 'press') core.scene.overlay('test', () => ({ draw() {}, mouse: () => true }));
           return true;
         } };
         core.scene.setRoot('test', () => ({
           layout: () => [{ view: opener, rect: { column: 0, row: 0, width: 5, height: 1 } }], draw() {},
         }));
         click(1, 0, 'press');
         click(1, 0, 'drag');
         click(1, 0, 'release');
         return log.join(', ');",
    )
    .await;
    assert_eq!(steps, "opener press");
}
