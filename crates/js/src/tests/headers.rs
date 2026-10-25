//! The web class of `yuke:internal/headers`: `Headers`. Many cases follow the web platform tests (WPT) of
//! `fetch/api/headers`.

use super::{NAMES, run};

#[tokio::test]
async fn a_name_ignores_case_and_get_joins_the_values() {
    let text = run::<String>(
        "a_name_ignores_case_and_get_joins_the_values",
        "const headers = new Headers({ 'Content-Type': 'text/plain' });
         headers.append('X-A', '1');
         headers.append('x-a', '2');
         const seen = [headers.get('x-a'), headers.has('CONTENT-TYPE'), headers.get('missing')];
         headers.delete('X-a');
         seen.push(headers.has('x-a'));
         return seen.join(' ');",
    )
    .await;

    assert_eq!(text, "1, 2 true  false");
}

#[tokio::test]
async fn iteration_gives_sorted_lower_case_names_and_keeps_each_set_cookie() {
    let text = run::<String>(
        "iteration_gives_sorted_lower_case_names_and_keeps_each_set_cookie",
        "const headers = new Headers([['B', '1'], ['Set-Cookie', 'x=1'], ['a', '2'], ['b', '3'], ['set-cookie', 'y=2']]);
         const visited = [];
         headers.forEach((value, name, parent) => visited.push(`${name}=${value}:${parent === headers}`));
         const keys = headers.keys();
         const first = keys.next().value;
         headers.append('c', '4');
         return [
           JSON.stringify([...headers]),
           visited.join(','),
           headers.getSetCookie().join(','),
           headers.get('set-cookie'),
           [first, ...keys].join(','),
           Object.prototype.toString.call(keys),
           keys instanceof Iterator,
         ].join(' ');",
    )
    .await;

    assert_eq!(
        text,
        r#"[["a","2"],["b","1, 3"],["c","4"],["set-cookie","x=1"],["set-cookie","y=2"]] a=2:true,b=1, 3:true,set-cookie=x=1:true,set-cookie=y=2:true x=1,y=2 x=1, y=2 a,b,c,set-cookie,set-cookie [object Headers Iterator] true"#
    );
}

#[tokio::test]
async fn set_replaces_the_first_value_and_removes_the_others() {
    let text = run::<String>(
        "set_replaces_the_first_value_and_removes_the_others",
        "const headers = new Headers([['A', '1'], ['b', '2'], ['a', '3']]);
         headers.set('a', 'x');
         headers.set('c', 'y');
         const copy = new Headers(headers);
         copy.append('d', '5');
         return [JSON.stringify([...headers]), headers.has('d'), [...copy.keys()].join(',')].join(' ');",
    )
    .await;

    assert_eq!(text, r#"[["a","x"],["b","2"],["c","y"]] false a,b,c,d"#);
}

#[tokio::test]
async fn a_value_loses_its_outer_whitespace_and_an_invalid_name_or_value_throws() {
    let text = run::<String>(
        "a_value_loses_its_outer_whitespace_and_an_invalid_name_or_value_throws",
        &format!(
            "{NAMES}
             const headers = new Headers([['a', ' \\t v w \\r\\n']]);
             return [
               JSON.stringify(headers.get('a')),
               headers.get('a') === new Headers({{ a: 'v w' }}).get('a'),
               names([
                 () => headers.append('bad name', 'x'),
                 () => headers.append('a', 'x\\ny'),
                 () => headers.append('a', 'x\\0y'),
                 () => headers.append('a', '€'),
                 () => headers.get('bad name'),
                 () => headers.has(''),
                 () => new Headers([['a']]),
                 () => new Headers('a: b'),
                 () => new Headers({{ [Symbol()]: 'x' }}),
                 () => headers.append('a'),
               ]),
               new Headers({{ a: 'é' }}).get('a'),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        r#""v w" true TypeError TypeError TypeError TypeError TypeError TypeError TypeError TypeError TypeError TypeError é"#
    );
}

#[tokio::test]
async fn immutable_headers_refuse_each_change() {
    let text = run::<String>(
        "immutable_headers_refuse_each_change",
        &format!(
            "{NAMES}
             const headers = Response.redirect('https://a.example/x').headers;
             return [
               names([() => headers.append('a', '1'), () => headers.set('a', '1'), () => headers.delete('location')]),
               headers.get('location'),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "TypeError TypeError TypeError https://a.example/x");
}

#[tokio::test]
async fn a_method_refuses_a_value_of_another_class() {
    let text = run::<String>(
        "a_method_refuses_a_value_of_another_class",
        &format!(
            "{NAMES}
             return [
               names([
                 () => Headers.prototype.get.call({{}}, 'a'),
                 () => Headers.prototype.entries.call({{}}),
                 () => new Headers().keys().next.call({{}}),
                 () => Headers.prototype.forEach.call({{}}, () => {{}}),
               ]),
               Object.prototype.toString.call(new Headers()),
               Headers.prototype[Symbol.iterator] === Headers.prototype.entries,
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(text, "TypeError TypeError TypeError TypeError [object Headers] true");
}
