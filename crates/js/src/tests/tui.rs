//! The core of the terminal interface: the keys, the keymap, the commands, the styles, and the notices.

use std::time::Duration;

use rquickjs::{Ctx, Module, Object};

use super::{NAMES, evaluate, folder, next_fault, start, wait_until};
use crate::Runtime;
use crate::error::caught;

/// Put each export of the core modules and of `yuke:tui` on the global object, and add the helpers of the tests:
/// `commands` and `keymap`, with `ran` (the runs), `faults`, and `frames` (the asks for a frame); `add(name, extra)`
/// adds a command that records its run; `key(char, mods, extra)` and `named(code, mods)` make key events; `CTRL`,
/// `ALT`, and `SHIFT` are the bits of `mods`.
async fn core(name: &str) -> Runtime {
    let (runtime, _reports) = start(&folder(name)).await;
    runtime
        .caller
        .run(async move |ctx: Ctx<'_>, _registry| {
            for module in [
                "yuke:tui",
                "yuke:internal/tui/keys",
                "yuke:internal/tui/keymap",
                "yuke:internal/tui/commands",
                "yuke:internal/tui/styles",
                "yuke:internal/tui/notices",
            ] {
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
        "globalThis.ran = [];
         globalThis.faults = [];
         globalThis.frames = 0;
         globalThis.commands = new Commands((text) => faults.push(text), () => { frames += 1; });
         globalThis.keymap = new Keymap(commands, () => {});
         globalThis.add = (name, extra = {}) => commands.add({
           name,
           run: (args) => { ran.push(args === undefined ? name : `${name}:${JSON.stringify(args)}`); },
           ...extra,
         });
         globalThis.CTRL = 4; globalThis.ALT = 2; globalThis.SHIFT = 1;
         globalThis.key = (char, mods = 0, extra = {}) =>
           ({ type: 'key', code: 'char', char, shifted: '', baseLayout: '', text: '', mods, ...extra });
         globalThis.named = (code, mods = 0) =>
           ({ type: 'key', code, char: '', shifted: '', baseLayout: '', text: '', mods });",
    )
    .await
    .unwrap();
    runtime
}

async fn text(runtime: &Runtime, body: &str) -> String {
    evaluate::<String>(runtime, body).await.unwrap()
}

#[tokio::test]
async fn a_spec_and_an_event_fold_to_the_same_stroke() {
    let runtime = core("a_spec_and_an_event_fold_to_the_same_stroke").await;
    let specs = text(
        &runtime,
        "return ['G', 'shift+g', 'ctrl+shift+A', '?', 'ctrl+space', 'shift+space', 'ctrl++', '+', 'shift+tab',
                 ' ctrl+x   ctrl+s ', 'alt+super+f35', 'esc']
           .map((spec) => parseKeys(spec).join(' ')).join(',');",
    )
    .await;
    assert_eq!(
        specs,
        "G,G,ctrl+a,?,ctrl+space,space,ctrl++,+,shift+tab,ctrl+x ctrl+s,alt+super+f35,esc"
    );
    let strokes = text(
        &runtime,
        "return [
           key('g', SHIFT, { shifted: 'G' }), key('g', SHIFT), key('A', CTRL | SHIFT), key('/', SHIFT, { shifted: '?' }),
           key(' ', CTRL), key(' ', SHIFT), key('+', CTRL), named('tab', SHIFT), named('esc'), named('unknown'),
           key(''), key('\\u0441', CTRL, { baseLayout: 'c' }), key('x', 16), key('x', 32),
         ].map(strokeOf).join(',');",
    )
    .await;
    // The Cyrillic key keeps its own stroke: a binding matches the typed key only. Hyper and meta take no binding.
    assert_eq!(
        strokes,
        "G,G,ctrl+a,?,ctrl+space,space,ctrl++,shift+tab,esc,,,ctrl+\u{441},,"
    );
}

#[tokio::test]
async fn a_spec_that_names_no_key_throws() {
    let runtime = core("a_spec_that_names_no_key_throws").await;
    let names = text(
        &runtime,
        &format!(
            "{NAMES} return names(['', '   ', 'ctrl+', 'hyper+a', 'enterr', '+a', 'a+', 5, 'shift+1', 'shift++',
               'ctrl+a'].map((spec) => () => parseKeys(spec)));"
        ),
    )
    .await;
    assert_eq!(
        names,
        "TypeError TypeError TypeError TypeError TypeError TypeError TypeError TypeError TypeError TypeError none"
    );
}

#[tokio::test]
async fn the_deepest_active_atom_wins_then_the_newest_binding() {
    let runtime = core("the_deepest_active_atom_wins_then_the_newest_binding").await;
    let order = text(
        &runtime,
        "for (const name of ['older', 'newer', 'list', 'global']) add(name);
         // The deepest binding is the oldest, so only its depth makes it win.
         keymap.bind('ctrl+k', 'list', { in: 'list' });
         keymap.bind('ctrl+k', 'older');
         keymap.bind('ctrl+k', 'newer');
         keymap.bind('ctrl+g', 'global', { in: 'global' });
         const taken = [
           keymap.key(key('k', CTRL), ['global', 'root']),
           keymap.key(key('k', CTRL), ['global', 'root', 'list']),
           keymap.key(key('k', CTRL), ['global', 'overlay']),
           keymap.key(key('g', CTRL), ['global', 'overlay']),
         ];
         return `${ran.join(' ')} ${taken.join(' ')}`;",
    )
    .await;
    assert_eq!(order, "newer list global true true false true");
}

#[tokio::test]
async fn a_disabled_command_passes_its_key_on_and_at_last_to_the_view() {
    let runtime = core("a_disabled_command_passes_its_key_on").await;
    let order = text(
        &runtime,
        "add('open');
         add('closed', { enabled: () => false });
         keymap.bind('x', 'open');
         keymap.bind('x', 'closed');
         keymap.bind('y', 'closed');
         keymap.bind('z', 'missing');
         const taken = ['x', 'y', 'z'].map((char) => keymap.key(key(char), ['global', 'root']));
         return `${ran.join(' ')} ${taken.join(' ')}`;",
    )
    .await;
    assert_eq!(order, "open true false false");
}

#[tokio::test]
async fn a_sequence_waits_for_its_next_stroke() {
    let runtime = core("a_sequence_waits_for_its_next_stroke").await;
    let steps = text(
        &runtime,
        "add('save');
         keymap.bind('ctrl+x ctrl+s', 'save');
         const atoms = ['global', 'root'];
         const first = keymap.key(key('x', CTRL), atoms);
         const pending = keymap.pending();
         const before = ran.length;
         const second = keymap.key(key('s', CTRL), atoms);
         return [first, pending, before, second, ran.join(' '), keymap.pending() === ''].join(' ');",
    )
    .await;
    assert_eq!(steps, "true ctrl+x 0 true save true");
}

#[tokio::test]
async fn a_sequence_prefix_runs_alone_after_the_wait() {
    let runtime = core("a_sequence_prefix_runs_alone_after_the_wait").await;
    evaluate::<()>(
        &runtime,
        "add('one'); add('top');
         keymap.bind('g', 'one');
         keymap.bind('g g', 'top');
         keymap.key(key('g'), ['global', 'root']);",
    )
    .await
    .unwrap();
    assert_eq!(
        text(&runtime, "return `${ran.length} ${keymap.pending()}`;").await,
        "0 g"
    );
    wait_until(&runtime, "return ran.length > 0;").await;
    assert_eq!(
        text(&runtime, "return `${ran.join(' ')} [${keymap.pending()}]`;").await,
        "one []"
    );
}

#[tokio::test]
async fn escape_cancels_a_sequence_and_an_unmatched_stroke_goes_on_as_a_new_key() {
    let runtime = core("escape_cancels_a_sequence").await;
    let steps = text(
        &runtime,
        "add('save'); add('alpha'); add('prefix');
         keymap.bind('ctrl+x ctrl+s', 'save');
         keymap.bind('ctrl+x', 'prefix');
         keymap.bind('a', 'alpha');
         const atoms = ['global', 'root'];
         keymap.key(key('x', CTRL), atoms);
         const escape = keymap.key(named('esc'), atoms);
         keymap.key(key('x', CTRL), atoms);
         const unmatched = keymap.key(key('a'), atoms);
         keymap.key(key('x', CTRL), atoms);
         keymap.cancel();
         const after = keymap.key(key('b'), atoms);
         return [escape, unmatched, after, ran.join('+'), keymap.pending() === ''].join(' ');",
    )
    .await;
    // The prefix binding never runs: escape, an unmatched stroke, and a cancel each drop it.
    assert_eq!(steps, "true true false alpha true");
    tokio::time::sleep(Duration::from_millis(1200)).await;
    assert_eq!(text(&runtime, "return ran.join('+');").await, "alpha");
}

#[tokio::test]
async fn a_binding_outside_the_active_atoms_neither_runs_nor_starts_a_sequence() {
    let runtime = core("a_binding_outside_the_active_atoms").await;
    let steps = text(
        &runtime,
        "add('save'); add('quit');
         keymap.bind('ctrl+x ctrl+s', 'save', { in: 'editor' });
         keymap.bind('ctrl+x', 'quit');
         const taken = keymap.key(key('x', CTRL), ['global', 'root']);
         return `${taken} ${ran.join(' ')} [${keymap.pending()}]`;",
    )
    .await;
    assert_eq!(steps, "true quit []");
}

#[tokio::test]
async fn a_deeper_single_key_runs_before_a_shallower_sequence_and_a_disabled_sequence_takes_no_key() {
    let runtime = core("a_deeper_single_key_runs_before_a_shallower_sequence").await;
    let steps = text(
        &runtime,
        "add('top'); add('down'); add('closed', { enabled: () => false });
         keymap.bind('g g', 'top');
         keymap.bind('g', 'down', { in: 'list' });
         keymap.bind('z z', 'closed');
         keymap.bind('q q', 'missing');
         const deeper = keymap.key(key('g'), ['global', 'root', 'list']);
         const waiting = `${deeper} [${keymap.pending()}] ${ran.join(' ')}`;
         const shallow = keymap.key(key('g'), ['global', 'root']);
         const pending = keymap.pending();
         keymap.cancel();
         const closed = [keymap.key(key('z'), ['global', 'root']), keymap.key(key('q'), ['global', 'root'])];
         return `${waiting} | ${shallow} ${pending} | ${closed.join(' ')} [${keymap.pending()}]`;",
    )
    .await;
    assert_eq!(steps, "true [] down | true g | false false []");
}

#[tokio::test]
async fn a_disposer_during_a_wait_cancels_the_wait() {
    let runtime = core("a_disposer_during_a_wait_cancels_the_wait").await;
    let steps = text(
        &runtime,
        "add('save');
         const dispose = keymap.bind('ctrl+x ctrl+s', 'save');
         keymap.key(key('x', CTRL), ['global', 'root']);
         const before = keymap.pending();
         dispose();
         return `${before} [${keymap.pending()}]`;",
    )
    .await;
    assert_eq!(steps, "ctrl+x []");
}

#[tokio::test]
async fn keys_of_a_command_and_each_disposer_remove_only_their_own_binding() {
    let runtime = core("keys_of_a_command_and_each_disposer").await;
    let steps = text(
        &runtime,
        "const first = keymap.bind('ctrl+p', 'palette');
         const second = keymap.bind('ctrl+p', 'palette');
         keymap.bind('alt+x  p', 'palette');
         keymap.bind('ctrl+q', 'quit');
         const all = keymap.keysOf('palette').join(',');
         first(); first();
         const kept = keymap.keysOf('palette').join(',');
         second();
         return `${all} | ${kept} | ${keymap.keysOf('palette').join(',')}`;",
    )
    .await;
    assert_eq!(steps, "alt+x p,ctrl+p | alt+x p,ctrl+p | alt+x p");
}

#[tokio::test]
async fn commands_check_their_names_and_run_with_args() {
    let runtime = core("commands_check_their_names_and_run_with_args").await;
    let steps = text(
        &runtime,
        &format!(
            "{NAMES}
             const dispose = add('notes:open', {{ title: 'Open a note' }});
             add('off', {{ enabled: () => false }});
             const thrown = names([() => add('notes:open'), () => add('a b'), () => add(''),
               () => commands.add({{ name: 'x' }}), () => add('t', {{ title: 7 }}), () => add('e', {{ enabled: true }})]);
             // A later change of the object changes neither the name nor the title.
             const renamed = {{ name: 'first', run: () => {{ ran.push('first'); }} }};
             commands.add(renamed);
             renamed.name = 'second';
             const runs = [commands.run('notes:open', {{ id: 3 }}), commands.run('off'), commands.run('missing'),
               commands.run('first'), commands.run('second')];
             const list = commands.list().map((item) => `${{item.name}}/${{item.title}}/${{item.enabled}}`).join(',');
             dispose(); dispose();
             return [thrown, runs.join(' '), ran.join(' '), list, commands.run('notes:open'), frames].join(' | ');"
        ),
    )
    .await;
    assert_eq!(
        steps,
        r#"TypeError TypeError TypeError TypeError TypeError TypeError | true false false true false | notes:open:{"id":3} first | notes:open/Open a note/true,off/off/false,first/first/true | false | 2"#
    );
}

#[tokio::test]
async fn an_async_command_lets_keys_go_on_and_a_failure_names_it() {
    let runtime = core("an_async_command_lets_keys_go_on").await;
    let steps = text(
        &runtime,
        "let finish;
         commands.add({ name: 'dialog', run: () => new Promise((resolve) => { finish = resolve; }) });
         commands.add({ name: 'broken', run: async () => { throw new Error('no disk'); } });
         commands.add({ name: 'sync', run: () => { throw new Error('bad state'); } });
         commands.add({ name: 'thenable', run: () => ({ then: (_resolve, reject) => reject(new Error('no then')) }) });
         add('next');
         keymap.bind('d', 'dialog');
         keymap.bind('n', 'next');
         const atoms = ['global', 'root'];
         keymap.key(key('d'), atoms);
         keymap.key(key('n'), atoms);
         const during = `${ran.join(' ')} ${frames}`;
         finish();
         await null;
         const after = frames;
         commands.run('broken');
         commands.run('sync');
         commands.run('thenable');
         for (let turn = 0; turn < 5; turn += 1) await null;
         return [during, after, frames, faults.map((fault) => fault.split('\\n')[0]).join(' / ')].join(' | ');",
    )
    .await;
    assert_eq!(
        steps,
        "next 1 | 2 | 5 | the command sync failed: Error: bad state / the command broken failed: Error: no disk / \
         the command thenable failed: Error: no then"
    );
}

#[tokio::test]
async fn a_throwing_enabled_check_counts_as_disabled_and_is_a_fault() {
    let runtime = core("a_throwing_enabled_check").await;
    let steps = text(
        &runtime,
        "add('flaky', { enabled: () => { throw new Error('no state'); } });
         const ran_it = commands.run('flaky');
         return `${ran_it} ${ran.length} ${faults[0].split('\\n')[0]}`;",
    )
    .await;
    assert_eq!(
        steps,
        "false 0 the enabled check of the command flaky failed: Error: no state"
    );
}

#[tokio::test]
async fn the_newest_style_layer_wins_per_field_and_null_deletes() {
    let runtime = core("the_newest_style_layer_wins_per_field").await;
    let steps = text(
        &runtime,
        "const styles = new Styles(() => true, () => 'dark');
         styles.set('title', { fg: 3, bold: true });
         const newer = styles.set('title', { fg: '#102030', bold: null, italic: true });
         const both = JSON.stringify(styles.resolve('title'));
         newer(); newer();
         return `${both} ${JSON.stringify(styles.resolve('title'))} ${JSON.stringify(styles.resolve('none'))}`;",
    )
    .await;
    assert_eq!(steps, r##"{"fg":"#102030","italic":true} {"fg":3,"bold":true} {}"##);
}

#[tokio::test]
async fn a_link_fills_the_missing_fields_and_a_cycle_stops() {
    let runtime = core("a_link_fills_the_missing_fields").await;
    let steps = text(
        &runtime,
        "const styles = new Styles(() => true, () => 'dark');
         styles.set('base', { fg: 1, bg: 2, underline: true });
         styles.set('title', { link: 'base', fg: 5 });
         const inline = styles.resolve({ link: 'title', bg: 'reset' });
         // Each order of the first resolves gives the same result in a cycle.
         const cycle = (order) => {
           const own = new Styles(() => true, () => 'dark');
           own.set('a', { link: 'b', bold: true });
           own.set('b', { link: 'a', dim: true });
           for (const name of order) own.resolve(name);
           return `${JSON.stringify(own.resolve('a'))}/${JSON.stringify(own.resolve('b'))}`;
         };
         return [JSON.stringify(styles.resolve('title')), JSON.stringify(inline), cycle(['a', 'b']), cycle(['b', 'a'])]
           .join(' ');",
    )
    .await;
    assert_eq!(
        steps,
        r#"{"fg":5,"bg":2,"underline":true} {"fg":5,"bg":"reset","underline":true} {"dim":true,"bold":true}/{"bold":true,"dim":true} {"dim":true,"bold":true}/{"bold":true,"dim":true}"#
    );
}

#[tokio::test]
async fn a_palette_color_follows_the_depth_and_the_background() {
    let runtime = core("a_palette_color_follows_the_depth").await;
    let steps = text(
        &runtime,
        "let truecolor = true;
         let background = 'dark';
         const styles = new Styles(() => truecolor, () => background);
         styles.set('accent', { fg: 'accent', bg: 'reset' });
         const seen = [styles.resolve('accent').fg];
         background = 'light';
         seen.push(styles.resolve('accent').fg);
         truecolor = false;
         seen.push(styles.resolve('accent').fg, styles.resolve({ bg: 'danger' }).bg);
         return seen.join(' ');",
    )
    .await;
    assert_eq!(steps, "#A8CFA0 #2D6A4F 29 124");
}

#[tokio::test]
async fn a_bad_style_field_throws() {
    let runtime = core("a_bad_style_field_throws").await;
    let names = text(
        &runtime,
        &format!(
            "{NAMES}
             const styles = new Styles(() => true, () => 'dark');
             return names([
               () => styles.set('a', {{ fg: 'red' }}), () => styles.set('a', {{ fg: 'toString' }}),
               () => styles.set('a', {{ fg: 256 }}), () => styles.set('a', {{ bold: 1 }}),
               () => styles.set('a', {{ color: 1 }}), () => styles.set('a', {{ link: '' }}), () => styles.set('', {{}}),
               () => styles.resolve({{ fg: null }}), () => styles.set('a', {{ fg: null, bg: 'surface', ul: '#ABCDEF' }}),
             ]);"
        ),
    )
    .await;
    assert_eq!(
        names,
        "TypeError TypeError TypeError TypeError TypeError TypeError TypeError TypeError none"
    );
}

#[tokio::test]
async fn notices_keep_the_last_hundred_and_count_a_repeat() {
    let runtime = core("notices_keep_the_last_hundred").await;
    let steps = text(
        &runtime,
        "const notices = new Notices();
         const seen = [];
         const dispose = notices.on((notice) => seen.push(`${notice.text}x${notice.count}`));
         notices.add('error', 'notes', 'broken');
         notices.add('error', 'notes', 'broken');
         notices.add('warn', 'notes', 'broken');
         dispose(); dispose();
         for (let index = 0; index < 120; index += 1) notices.add('info', 'host:yuke', `n${index}`);
         const list = notices.list();
         return [seen.join(' '), list.length, list[0].text, list.at(-1).text, Object.isFrozen(list[0])].join(' ');",
    )
    .await;
    assert_eq!(steps, "brokenx1 brokenx2 brokenx1 100 n20 n119 true");
}

#[tokio::test]
async fn a_throwing_notice_listener_is_reported_and_the_next_listener_runs() {
    let folder = folder("a_throwing_notice_listener_is_reported");
    let (runtime, mut reports) = start(&folder).await;
    runtime
        .caller
        .run(async move |ctx: Ctx<'_>, _registry| {
            let promise = caught(&ctx, Module::import(&ctx, "yuke:internal/tui/notices"))?;
            let namespace = caught(&ctx, promise.into_future::<Object<'_>>().await)?;
            let notices = caught(&ctx, namespace.get::<_, rquickjs::Value<'_>>("Notices"))?;
            caught(&ctx, ctx.globals().set("Notices", notices))
        })
        .await
        .unwrap();
    let seen = text(
        &runtime,
        "const notices = new Notices();
         const seen = [];
         notices.on(() => { throw new Error('a broken listener'); });
         notices.on((notice) => seen.push(notice.text));
         notices.add('info', 'notes', 'hello');
         return seen.join(' ');",
    )
    .await;
    assert_eq!(seen, "hello");
    let fault = next_fault(&mut reports).await;
    assert!(fault.message.contains("a broken listener"), "{fault:?}");
}

#[tokio::test]
async fn the_public_module_works_without_a_display() {
    let runtime = core("the_public_module_works_without_a_display").await;
    let steps = text(
        &runtime,
        "return [measure('a\\u4e2d'), fit('a\\u4e2db', 3), Array.from(wrap('ab cd', 3)).join(','),
                 Array.from(graphemes('ab')).join(','), parseKeys('ctrl+x s').join(' ')].join(' ');",
    )
    .await;
    assert_eq!(steps, "3 2 0,3,1,3,5,0 0,1,1,1,1,1 ctrl+x s");
}
