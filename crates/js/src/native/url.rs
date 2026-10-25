//! The URL functions of the native module for `URL` and `URLSearchParams`, on the WHATWG parser of the `url` crate.
//! The text that reaches them is well formed: the classes convert each argument as a `USVString` first.

use rquickjs::convert::List;
use rquickjs::{Ctx, Function, IntoJs, Object};
use url::{Url, form_urlencoded, quirks};

use crate::error::{ErrorClass, throw};

/// Add `parseUrl`, `updateUrl`, `parseQuery`, and `serializeQuery` to `object`, the export object of the native module.
pub(super) fn add<'js>(ctx: &Ctx<'js>, object: &Object<'js>) -> rquickjs::Result<()> {
    object.set(
        "parseUrl",
        Function::new(ctx.clone(), |input: String, base: Option<String>| {
            parse(&input, base.as_deref()).map(|url| Parts::of(&url))
        })?,
    )?;
    object.set(
        "updateUrl",
        Function::new(
            ctx.clone(),
            |ctx: Ctx<'js>, href: String, component: String, value: String| {
                let Ok(mut url) = Url::parse(&href) else {
                    return Err(throw(&ctx, ErrorClass::TypeError, "the href is not a valid URL"));
                };
                match update(&mut url, &component, &value) {
                    Some(changed) => Ok(changed.then(|| Parts::of(&url))),
                    None => Err(throw(
                        &ctx,
                        ErrorClass::TypeError,
                        &format!("the URL has no component '{component}'"),
                    )),
                }
            },
        )?,
    )?;
    object.set(
        "parseQuery",
        Function::new(ctx.clone(), |text: String| {
            form_urlencoded::parse(text.as_bytes())
                .into_owned()
                .map(List)
                .collect::<Vec<_>>()
        })?,
    )?;
    object.set(
        "serializeQuery",
        Function::new(ctx.clone(), |pairs: Vec<List<(String, String)>>| {
            form_urlencoded::Serializer::new(String::new())
                .extend_pairs(pairs.into_iter().map(|List(pair)| pair))
                .finish()
        })?,
    )?;
    Ok(())
}

/// The URL of `input` against `base`, or `None` when `input` or `base` is not valid.
fn parse(input: &str, base: Option<&str>) -> Option<Url> {
    match base {
        Some(base) => Url::parse(base).ok()?.join(input).ok(),
        None => Url::parse(input).ok(),
    }
}

/// Run the setter of `component` with `value`. `Some(false)` means that the setter refuses the value, so the URL stays
/// as it was, and `None` means that `component` names no setter.
fn update(url: &mut Url, component: &str, value: &str) -> Option<bool> {
    let changed = match component {
        "protocol" => quirks::set_protocol(url, value).is_ok(),
        "username" => quirks::set_username(url, value).is_ok(),
        "password" => quirks::set_password(url, value).is_ok(),
        "host" => quirks::set_host(url, value).is_ok(),
        "hostname" => quirks::set_hostname(url, value).is_ok(),
        "port" => quirks::set_port(url, value).is_ok(),
        "pathname" => {
            quirks::set_pathname(url, value);
            true
        }
        "search" => {
            quirks::set_search(url, value);
            true
        }
        "hash" => {
            quirks::set_hash(url, value);
            true
        }
        _ => return None,
    };
    Some(changed)
}

/// The values of the getters of a `URL`.
#[derive(IntoJs)]
struct Parts {
    href: String,
    origin: String,
    protocol: String,
    username: String,
    password: String,
    host: String,
    hostname: String,
    port: String,
    pathname: String,
    search: String,
    hash: String,
}

impl Parts {
    fn of(url: &Url) -> Self {
        Self {
            href: quirks::href(url).to_owned(),
            origin: quirks::origin(url),
            protocol: quirks::protocol(url).to_owned(),
            username: quirks::username(url).to_owned(),
            password: quirks::password(url).to_owned(),
            host: quirks::host(url).to_owned(),
            hostname: quirks::hostname(url).to_owned(),
            port: quirks::port(url).to_owned(),
            pathname: quirks::pathname(url).to_owned(),
            search: quirks::search(url).to_owned(),
            hash: quirks::hash(url).to_owned(),
        }
    }
}
