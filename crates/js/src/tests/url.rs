//! The web classes of `yuke:internal/url`: `URL` and `URLSearchParams`. Many cases follow the web platform tests (WPT)
//! of `url`.

use super::{NAMES, run};

#[tokio::test]
async fn a_url_resolves_against_its_base_and_gives_each_component() {
    let text = run::<String>(
        "a_url_resolves_against_its_base_and_gives_each_component",
        "const url = new URL('../c d?x=1#f', 'HTTPS://user:pw@EXAMPLE.com:8080/a/b/');
         return [url.href, url.origin, url.protocol, url.username, url.password, url.host, url.hostname, url.port,
           url.pathname, url.search, url.hash].join(' ');",
    )
    .await;

    assert_eq!(
        text,
        "https://user:pw@example.com:8080/a/c%20d?x=1#f https://example.com:8080 https: user pw example.com:8080 \
         example.com 8080 /a/c%20d ?x=1 #f"
    );
}

#[tokio::test]
async fn a_host_with_unicode_becomes_punycode_and_an_opaque_origin_is_null() {
    let text = run::<String>(
        "a_host_with_unicode_becomes_punycode_and_an_opaque_origin_is_null",
        "return [
           new URL('https://bücher.example/').hostname,
           new URL('https://faß.de/').hostname,
           new URL('https://example.com:443/').port,
           new URL('data:text/plain,x').origin,
         ].join(' ');",
    )
    .await;

    assert_eq!(text, "xn--bcher-kva.example xn--fa-hia.de  null");
}

#[tokio::test]
async fn an_invalid_url_throws_and_parse_gives_null() {
    let text = run::<String>(
        "an_invalid_url_throws_and_parse_gives_null",
        &format!(
            "{NAMES}
             let message = '';
             try {{ new URL('/a', 'no base'); }} catch (error) {{ message = error.message; }}
             return [
               names([() => new URL('no scheme'), () => new URL('/a', 'no base'), () => new URL('https://a b/')]),
               message,
               URL.parse('no scheme'),
               URL.parse('/a', 'https://a.example/b').href,
               URL.parse('https://a.example/') instanceof URL,
               URL.canParse('no scheme'),
               URL.canParse('/a', 'https://a.example/'),
             ].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        "TypeError TypeError TypeError '/a' with the base 'no base' is not a valid URL  https://a.example/a true \
         false true"
    );
}

#[tokio::test]
async fn a_setter_parses_its_component_and_a_refused_value_keeps_the_url() {
    let text = run::<String>(
        "a_setter_parses_its_component_and_a_refused_value_keeps_the_url",
        "const url = new URL('https://a.example/p');
         url.port = '8080';
         url.port = 'x';
         url.protocol = 'ftp';
         url.protocol = 'mailto';
         url.username = 'me';
         url.hostname = 'b.example';
         url.pathname = 'a b';
         url.search = 'q=1';
         url.hash = 'top';
         const changed = url.href;
         url.port = '';
         url.search = '';
         url.hash = '';
         return `${changed} ${url.href}`;",
    )
    .await;

    assert_eq!(text, "ftp://me@b.example:8080/a%20b?q=1#top ftp://me@b.example/a%20b");
}

#[tokio::test]
async fn an_href_that_is_not_a_url_throws_and_keeps_the_url() {
    let text = run::<String>(
        "an_href_that_is_not_a_url_throws_and_keeps_the_url",
        &format!(
            "{NAMES}
             const url = new URL('https://a.example/');
             const thrown = names([() => {{ url.href = 'no scheme'; }}]);
             const kept = url.href;
             url.href = 'http://b.example/x';
             return [thrown, kept, url.href, String(url), JSON.stringify({{ url }})].join(' ');"
        ),
    )
    .await;

    assert_eq!(
        text,
        r#"TypeError https://a.example/ http://b.example/x http://b.example/x {"url":"http://b.example/x"}"#
    );
}

#[tokio::test]
async fn the_search_params_of_a_url_follow_its_query_and_set_it() {
    let text = run::<String>(
        "the_search_params_of_a_url_follow_its_query_and_set_it",
        "const url = new URL('https://a.example/?a=1&b=2');
         const params = url.searchParams;
         const seen = [params === url.searchParams];
         params.append('c', 'x y');
         seen.push(url.search);
         url.search = '?z=9';
         seen.push(params.get('z'), params.has('a'));
         params.delete('z');
         seen.push(url.href);
         url.href = 'https://b.example/?q=1';
         seen.push(params.get('q'), params.size);
         return seen.join(' ');",
    )
    .await;

    assert_eq!(text, "true ?a=1&b=2&c=x+y 9 false https://a.example/ 1 1");
}

#[tokio::test]
async fn the_search_params_of_an_opaque_path_drop_its_trailing_spaces_with_the_query() {
    let text = run::<String>(
        "the_search_params_of_an_opaque_path_drop_its_trailing_spaces_with_the_query",
        "const url = new URL('data:space    ?query');
         url.searchParams.delete('query');
         return JSON.stringify(url.href);",
    )
    .await;

    assert_eq!(text, r#""data:space""#);
}

#[tokio::test]
async fn search_params_take_a_query_string_pairs_or_a_record() {
    let text = run::<String>(
        "search_params_take_a_query_string_pairs_or_a_record",
        "return [
           new URLSearchParams('?a=1&a=2').getAll('a').join(','),
           JSON.stringify(new URLSearchParams('b=%20+x&%zz=%C3').get('b')),
           new URLSearchParams('%zz=%C3').toString(),
           new URLSearchParams([['a', '1'], new Set(['b', '2'])]).toString(),
           new URLSearchParams({ x: '1', y: 2 }).toString(),
           new URLSearchParams(new URLSearchParams('k=v')).toString(),
           new URLSearchParams(null).toString(),
           new URLSearchParams().size,
           new URLSearchParams({ b: '1', 2: 'x', 1: 'y' }).toString(),
           new URLSearchParams(Object.assign(() => {}, { f: '1' })).toString(),
         ].join(' ');",
    )
    .await;

    assert_eq!(
        text,
        r#"1,2 "  x" %25zz=%EF%BF%BD a=1&b=2 x=1&y=2 k=v null= 0 1=y&2=x&b=1 f=1"#
    );
}

#[tokio::test]
async fn a_pair_without_exactly_two_values_or_a_symbol_key_throws_a_type_error() {
    let text = run::<String>(
        "a_pair_without_exactly_two_values_or_a_symbol_key_throws_a_type_error",
        &format!(
            "{NAMES}
             return names([
               () => new URLSearchParams([['a']]),
               () => new URLSearchParams([['a', 'b', 'c']]),
               () => new URLSearchParams([1]),
               () => new URLSearchParams([{{ length: 2, 0: 'a', 1: 'b' }}]),
               () => new URLSearchParams({{ [Symbol.iterator]: 1 }}),
               () => new URLSearchParams({{ [Symbol()]: 'x' }}),
             ]);"
        ),
    )
    .await;

    assert_eq!(text, ["TypeError"; 6].join(" "));
}

#[tokio::test]
async fn search_params_encode_as_application_x_www_form_urlencoded() {
    let text = run::<String>(
        "search_params_encode_as_application_x_www_form_urlencoded",
        "return new URLSearchParams({ 'a b': 'é&=+*-._~?' }).toString();",
    )
    .await;

    assert_eq!(text, "a+b=%C3%A9%26%3D%2B*-._%7E%3F");
}

#[tokio::test]
async fn set_delete_has_and_sort_keep_the_order_of_the_other_pairs() {
    let text = run::<String>(
        "set_delete_has_and_sort_keep_the_order_of_the_other_pairs",
        "const params = new URLSearchParams('b=1&a=2&b=3&c=4&a=5');
         const seen = [];
         params.set('b', 'x');
         seen.push(params.toString());
         params.sort();
         seen.push(params.toString());
         params.delete('a', '5');
         seen.push(params.toString(), params.has('a', '2'), params.has('a', '5'), params.has('c'), params.get('z'));
         params.delete('a', undefined);
         seen.push(params.toString());
         return seen.join(' ');",
    )
    .await;

    assert_eq!(
        text,
        "b=x&a=2&c=4&a=5 a=2&a=5&b=x&c=4 a=2&b=x&c=4 true false true  b=x&c=4"
    );
}

#[tokio::test]
async fn an_iterator_and_for_each_see_a_change_of_the_pairs() {
    let text = run::<String>(
        "an_iterator_and_for_each_see_a_change_of_the_pairs",
        "const params = new URLSearchParams('a=1&b=2');
         const keys = params.keys();
         const first = keys.next().value;
         params.append('c', '3');
         const rest = [...keys].join(',');
         const visited = [];
         params.forEach(function (value, name, parent) {
           visited.push(`${name}${value}${parent === params}${this.mark}`);
           if (name === 'a') params.append('d', '4');
         }, { mark: '!' });
         return [
           first,
           rest,
           visited.join(','),
           JSON.stringify([...params]),
           [...params.values()].join(','),
           params[Symbol.iterator] === params.entries,
           Object.prototype.toString.call(params.entries()),
           params.entries() instanceof Iterator,
         ].join(' ');",
    )
    .await;

    assert_eq!(
        text,
        r#"a b,c a1true!,b2true!,c3true!,d4true! [["a","1"],["b","2"],["c","3"],["d","4"]] 1,2,3,4 true [object URLSearchParams Iterator] true"#
    );
}

#[tokio::test]
async fn a_method_refuses_a_value_of_another_class_and_a_missing_argument() {
    let text = run::<String>(
        "a_method_refuses_a_value_of_another_class_and_a_missing_argument",
        &format!(
            "{NAMES}
             const getter = (type, name) => Object.getOwnPropertyDescriptor(type.prototype, name).get;
             const params = new URLSearchParams();
             return names([
               () => getter(URL, 'href').call({{}}),
               () => URLSearchParams.prototype.get.call({{}}, 'a'),
               () => params.entries().next.call({{}}),
               () => new URL(),
               () => params.append('a'),
               () => params.get(),
               () => params.forEach(1),
               () => URL('https://a.example/'),
             ]);"
        ),
    )
    .await;

    assert_eq!(text, ["TypeError"; 8].join(" "));
}

#[tokio::test]
async fn the_static_methods_are_enumerable_as_web_idl_operations() {
    let text = run::<String>(
        "the_static_methods_are_enumerable_as_web_idl_operations",
        "return Object.keys(URL).join(',');",
    )
    .await;

    assert_eq!(text, "parse,canParse");
}

#[tokio::test]
async fn each_class_names_itself_in_its_string_form() {
    let text = run::<String>(
        "each_class_names_itself_in_its_string_form",
        "return [new URL('https://a.example/'), new URLSearchParams()]
           .map((value) => Object.prototype.toString.call(value)).join(' ');",
    )
    .await;

    assert_eq!(text, "[object URL] [object URLSearchParams]");
}
