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
            for module in ["yuke:internal/tui/core", "yuke:internal/tui/surface", "yuke:tui"] {
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
           quit: () => calls.push('quit'), suspend: () => calls.push('suspend'),
           reload: (snapshot) => calls.push(`reload ${snapshot}`), copy: (text) => calls.push(`copy ${text}`),
         };
         globalThis.driver = driver;
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
         const panes = createSurface(core, 'test', new AbortController().signal).panes;
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
         const panes = createSurface(core, 'test', new AbortController().signal).panes;
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
    assert_eq!(steps, r#"quit suspend reload {"tree":null,"focus":0}"#);
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
         const pane = createSurface(core, 'test', new AbortController().signal).panes.split((mount) => { mount.close(); return { draw() {} }; });
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
        "const panes = createSurface(core, 'test', new AbortController().signal).panes;
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

/// The views of the tests of restore: a note shows its id and saves it; `note(id)` is the factory of a new note.
const NOTE: &str = "globalThis.note = (state) => ({
       draw: (canvas, focused) => { canvas.text(0, 0, `${focused ? 'N' : 'n'}ote ${state.id}`); },
       snapshot: () => ({ type: 'note', state }),
     });";

#[tokio::test]
async fn a_bare_name_gets_the_plugin_prefix_and_a_foreign_prefix_throws() {
    let runtime = scene("a_bare_name_gets_the_plugin_prefix").await;
    let steps = text(
        &runtime,
        "const tui = createSurface(core, 'notes', new AbortController().signal);
         tui.commands.add({ name: 'open', run: () => log.push('open') });
         tui.keys.bind('ctrl+n', 'open');
         tui.views.register('note', () => ({ draw() {} }));
         const thrown = [() => tui.commands.add({ name: 'other:x', run() {} }), () => tui.views.register('core:note', () => {})]
           .map((call) => { try { call(); return 'none'; } catch (error) { return error.name; } }).join(' ');
         tui.commands.add({ name: 'notes:close', run() {} });
         const ran = [tui.commands.run('open'), tui.commands.run('core:quit')];
         const names = tui.commands.list().map((item) => item.name).filter((name) => name.startsWith('notes:'));
         return [thrown, ran.join(' '), log.join(' '), calls.join(' '), names.join(' '), tui.keys.keysOf('open').join(' '),
           core.views.get('notes:note') !== undefined].join(' | ');",
    )
    .await;
    assert_eq!(
        steps,
        "TypeError TypeError | true true | open | quit | notes:open notes:close | ctrl+n | true"
    );
}

#[tokio::test]
async fn the_stop_of_a_plugin_removes_its_registrations_and_mounts_and_later_calls_throw() {
    let runtime = scene("the_stop_of_a_plugin_removes_its_registrations").await;
    let steps = text(
        &runtime,
        "const stop = new AbortController();
         // A listener of the plugin that runs before the one of the surface sees a stopped surface too.
         stop.signal.addEventListener('abort', () => {
           try { tui.commands.add({ name: 'during', run() {} }); } catch (error) { log.push(error.name); }
         });
         const tui = createSurface(core, 'notes', stop.signal);
         const once = tui.commands.add({ name: 'open', run() {} });
         once();
         tui.commands.add({ name: 'open', run() {} });
         tui.keys.bind('ctrl+n', 'open');
         tui.styles.set('notes.title', { bold: true });
         tui.notices.on(() => log.push('heard'));
         tui.views.register('note', () => ({ draw() {} }));
         const pane = tui.panes.split(() => ({ draw: (canvas) => { canvas.text(0, 0, 'pane'); } }));
         const overlay = tui.overlay(() => ({ draw() {} }), { modal: false, place: () => ({ column: 0, row: 5, width: 1, height: 1 }) });
         const root = tui.setRoot(() => ({ draw: (canvas) => { canvas.text(0, 0, 'root'); } }));
         const before = screen()[0];
         stop.abort();
         core.notices.add('info', 'core', 'after');
         let thrown = 'none';
         try { tui.commands.add({ name: 'late', run() {} }); } catch (error) { thrown = error.name; }
         once(); root.close();
         return [before, screen()[0], [pane, overlay, root].map((mount) => mount.signal.aborted).join(' '),
           core.commands.list().some((item) => item.name.startsWith('notes:')), core.keymap.keysOf('notes:open').length,
           JSON.stringify(core.styles.resolve('notes.title')), String(core.views.get('notes:note')), log.join(' '), thrown].join(' | ');",
    )
    .await;
    // After the stop the pane tree is a placeholder again: the root, the pane, and the overlay of the plugin are gone.
    assert_eq!(
        steps,
        "root | empty | true true true | false | 0 | {} | undefined | TypeError | TypeError"
    );
}

#[tokio::test]
async fn a_command_of_a_plugin_keeps_its_this_and_its_fault_names_the_plugin() {
    let runtime = scene("a_command_of_a_plugin_keeps_its_this").await;
    let steps = text(
        &runtime,
        "class Counter { count = 0; name = 'count'; run() { this.count += 1; } }
         const counter = new Counter();
         const tui = createSurface(core, 'notes', new AbortController().signal);
         tui.commands.add(counter);
         tui.commands.add({ name: 'broken', run: () => { throw new Error('no disk'); } });
         tui.commands.run('count'); tui.commands.run('count'); tui.commands.run('broken');
         const fault = core.notices.list().at(-1);
         return `${counter.count} ${fault.source} ${fault.text.split('\\n')[0]}`;",
    )
    .await;
    assert_eq!(steps, "2 notes the command notes:broken failed: Error: no disk");
}

#[tokio::test]
async fn the_panes_of_a_snapshot_come_back_with_their_views_and_focus() {
    let runtime = scene("the_panes_of_a_snapshot_come_back").await;
    evaluate::<()>(&runtime, NOTE).await.unwrap();
    let steps = text(
        &runtime,
        "const tui = createSurface(core, 'notes', new AbortController().signal);
         tui.views.register('note', note);
         const one = tui.panes.split(() => note({ id: 1 }));
         tui.panes.split(() => note({ id: 2 }), { direction: 'column' });
         tui.panes.split(() => ({ draw() {} }));
         // A state that is no JSON value saves as `null`, with a notice.
         const cycle = { id: 3 };
         cycle.self = cycle;
         tui.panes.split(() => note(cycle), { direction: 'column' });
         screen();
         one.focus();
         const before = screen();
         const snapshot = core.snapshot();
         const cycleNotice = core.notices.list().at(-1);
         globalThis.core = new Core(driver, () => ({ draw: (canvas) => { canvas.text(0, 0, 'empty'); } }));
         createSurface(core, 'notes', new AbortController().signal).views.register('note', note);
         core.restore(snapshot);
         return `${snapshot} | ${before.join('/')} | ${screen().join('/')} | ${cycleNotice.source}: ${cycleNotice.text.split(':')[0]}`;",
    )
    .await;
    // The placeholder and the view without `snapshot()` save as `null`; the focus is the index of note 1. After the
    // restore the layout and the focus are the same, and the view without a snapshot is a placeholder.
    let tree = r#"{"tree":{"split":"row","ratio":0.5,"first":null,"second":{"split":"column","ratio":0.5,"first":{"type":"notes:note","state":{"id":1}},"second":{"split":"row","ratio":0.5,"first":{"type":"notes:note","state":{"id":2}},"second":{"split":"column","ratio":0.5,"first":null,"second":null}}}},"focus":1}"#;
    let before = "empty     │Note 1/          │/          │/          │─────────/          │note│/          │    │────";
    let after =
        "empty     │Note 1/          │/          │/          │─────────/          │note│empt/          │    │────";
    let notice = "notes: the snapshot of a pane is no JSON value";
    assert_eq!(steps, format!("{tree} | {before} | {after} | {notice}"));
}

#[tokio::test]
async fn a_restore_drops_a_pane_without_its_plugin_and_keeps_a_placeholder_for_a_failed_one() {
    let runtime = scene("a_restore_drops_a_pane_without_its_plugin").await;
    evaluate::<()>(&runtime, NOTE).await.unwrap();
    let steps = text(
        &runtime,
        "const notes = new AbortController();
         const tui = createSurface(core, 'notes', notes.signal);
         tui.views.register('note', note);
         const earlier = tui.panes.split(() => note({ id: 9 }));
         createSurface(core, 'broken', new AbortController().signal).views.register('view', () => {
           throw new Error('old state');
         });
         const split = (first, second) => ({ split: 'row', ratio: 0.5, first, second });
         const saved = { tree: split(split({ type: 'gone:view', state: 1 }, { type: 'notes:note', state: { id: 3 } }),
           { type: 'broken:view', state: 2 }), focus: 0 };
         core.restore(JSON.stringify(saved));
         const rows = screen();
         // The restore closes the panes from before it.
         const closed = earlier.signal.aborted;
         const fault = core.notices.list().at(-1);
         core.restore('not json');
         const unread = core.notices.list().at(-1).text.split(':')[0];
         // A snapshot that does not read gives the default layout: the restored note closes.
         const afterBad = screen()[0];
         // The stop of `notes` closes its restored pane too.
         notes.abort();
         return `${rows[0]} | ${closed} | ${fault.source}: ${fault.text.split('\\n')[0]} | ${unread} | ${afterBad} | ${screen()[0]}`;",
    )
    .await;
    // `gone:view` has no factory: its pane goes, and note 3 takes its place, with the focus of the gone leaf.
    assert_eq!(
        steps,
        "Note 3    │empty | true | broken: a view did not start: Error: old state | the saved panes did not read | empty | empty"
    );
}

#[tokio::test]
async fn a_focus_out_of_the_tree_and_a_state_that_is_no_json_value_give_a_notice() {
    let runtime = scene("a_focus_out_of_the_tree").await;
    let steps = text(
        &runtime,
        "const tui = createSurface(core, 'notes', new AbortController().signal);
         tui.panes.split(() => ({ draw() {}, snapshot: () => ({ type: 'note', state: undefined }) }));
         const saved = core.snapshot();
         const stateNotice = core.notices.list().at(-1).text.split(':')[0];
         core.restore(JSON.stringify({ tree: null, focus: 1 }));
         return `${saved} | ${stateNotice} | ${core.notices.list().at(-1).text.split('\\n')[0]}`;",
    )
    .await;
    assert_eq!(
        steps,
        r#"{"tree":{"split":"row","ratio":0.5,"first":null,"second":null},"focus":1} | the snapshot of a pane is no JSON value | the saved panes did not read: TypeError: the focus of a snapshot is the index of a leaf"#
    );
}
