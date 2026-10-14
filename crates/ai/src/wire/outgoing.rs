//! Build the URL and headers of one request from its route and credential. The encoder adds the body.

use crate::encoder::EncodeError;
use crate::request::{OriginRef, Protocol, Target};
use crate::route::{self, Credential, CredentialHeader};
use crate::transport::Header;

/// The URL, the headers, and the origin of one request.
#[derive(Debug, Default)]
pub(crate) struct HeadText {
    pub(crate) url: String,
    pub(crate) headers: Vec<Header>,
    pub(crate) model: String,
    pub(crate) base_url: String,
}

impl HeadText {
    /// Copy the URL, the headers, and the origin of a request to `target`. Headers go in credential, identity,
    /// route, and session order.
    pub(crate) fn build(&mut self, target: &Target, session_id: Option<&str>) -> Result<(), EncodeError> {
        let route = &target.route;
        let credential = &target.credential;
        if route.credential_header.is_none() != matches!(credential, Credential::None) {
            return Err(EncodeError::CredentialMismatch);
        }
        let (secret, identity): (&str, &[Header]) = match credential {
            Credential::None => ("", &[]),
            Credential::ApiKey(key) => (key, &[]),
            Credential::OAuth(grant) => (&grant.access_token, &grant.headers),
        };
        let session = route.session_header.name().zip(session_id);
        // The encoder writes these two headers. A second copy of one lets a gateway choose either value.
        let written = [
            route.credential_header.map_or("", CredentialHeader::name),
            session.map_or("", |(name, _)| name),
        ];
        let invalid = route::invalid_header(identity, &written)
            .or_else(|| route::invalid_header(&route.headers, &written))
            .or_else(|| (!route::valid_header_value(secret)).then_some(written[0]))
            .or_else(|| session.and_then(|(name, value)| (!route::valid_header_value(value)).then_some(name)));
        if let Some(name) = invalid {
            return Err(EncodeError::InvalidHeader { name: name.to_owned() });
        }

        // A final slash on the base gives one separator, not two.
        let base_url = route.base_url.trim_end_matches('/');
        self.url = format!("{base_url}{}", protocol_path(target.wire.protocol()));
        let origin = OriginRef::of(target);
        origin.model.clone_into(&mut self.model);
        origin.base_url.clone_into(&mut self.base_url);

        self.headers.clear();
        if let Some(header) = route.credential_header {
            let prefix = match header {
                CredentialHeader::XApiKey | CredentialHeader::ApiKey => "",
                CredentialHeader::AuthorizationBearer => "Bearer ",
            };
            self.headers
                .push(Header::new(header.name(), format!("{prefix}{secret}")));
        }
        self.headers
            .extend(identity.iter().chain(route.headers.iter()).cloned());
        if let Some((name, value)) = session {
            self.headers.push(Header::new(name, value.to_owned()));
        }
        Ok(())
    }

    pub(crate) fn origin(&self) -> OriginRef<'_> {
        OriginRef {
            model: &self.model,
            base_url: &self.base_url,
        }
    }
}

fn protocol_path(protocol: Protocol) -> &'static str {
    match protocol {
        Protocol::AnthropicMessages => "/messages",
        Protocol::OpenaiChat => "/chat/completions",
        Protocol::OpenaiResponses => "/responses",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::{AnthropicWire, ChatWire, ResponsesWire, Wire};
    use crate::route::{OAuth, Route, SessionHeader};
    use crate::testing::assert_same;

    fn header(name: &str, value: &str) -> Header {
        Header::new(name.to_owned(), value.to_owned())
    }

    fn invalid(name: &str) -> EncodeError {
        EncodeError::InvalidHeader { name: name.to_owned() }
    }

    fn try_build(
        route: &Route,
        protocol: Protocol,
        credential: &Credential,
        session_id: Option<&str>,
    ) -> Result<HeadText, EncodeError> {
        let wire = match protocol {
            Protocol::AnthropicMessages => Wire::AnthropicMessages(AnthropicWire {
                max_tokens: 8,
                cache: false,
            }),
            Protocol::OpenaiChat => Wire::OpenaiChat(ChatWire::default()),
            Protocol::OpenaiResponses => Wire::OpenaiResponses(ResponsesWire::default()),
        };
        let target = Target {
            model: "m".into(),
            route: route.clone(),
            credential: credential.clone(),
            wire,
            tool_search: false,
        };
        let mut head = HeadText::default();
        head.build(&target, session_id)?;
        Ok(head)
    }

    fn built(route: &Route, protocol: Protocol, credential: &Credential, session_id: Option<&str>) -> HeadText {
        try_build(route, protocol, credential, session_id).unwrap()
    }

    #[test]
    fn header_order_per_credential() {
        struct Case<'a> {
            name: &'a str,
            route: Route,
            credential: Credential,
            session_id: Option<&'a str>,
            want: Vec<Header>,
        }
        let languages = [
            header("originator", "example"),
            header("Accept-Language", "en"),
            header("accept-language", "es"),
        ];
        let cases = [
            Case {
                name: "anthropic api key",
                route: Route {
                    base_url: "https://api.anthropic.com/v1".into(),
                    headers: vec![header("anthropic-version", "2023-06-01")].into(),
                    credential_header: Some(CredentialHeader::XApiKey),
                    ..Route::default()
                },
                credential: Credential::ApiKey("sk-secret".into()),
                session_id: None,
                want: vec![
                    header("x-api-key", "sk-secret"),
                    header("anthropic-version", "2023-06-01"),
                ],
            },
            Case {
                name: "compat host bearer",
                route: Route {
                    base_url: "https://llm.acme/v1".into(),
                    credential_header: Some(CredentialHeader::AuthorizationBearer),
                    ..Route::default()
                },
                credential: Credential::ApiKey("sk-2".into()),
                session_id: None,
                want: vec![header("Authorization", "Bearer sk-2")],
            },
            Case {
                name: "azure api key",
                route: Route {
                    base_url: "https://res.openai.azure.com/openai/v1".into(),
                    credential_header: Some(CredentialHeader::ApiKey),
                    ..Route::default()
                },
                credential: Credential::ApiKey("az-key".into()),
                session_id: None,
                want: vec![header("api-key", "az-key")],
            },
            // An oauth grant is a bearer that carries its own identity header. A list-valued route header keeps its
            // repeated lines in order, and the session id comes last.
            Case {
                name: "oauth grant with a session",
                route: Route {
                    base_url: "https://example.test/v1".into(),
                    headers: languages.to_vec().into(),
                    session_header: SessionHeader::SessionId,
                    credential_header: Some(CredentialHeader::AuthorizationBearer),
                },
                credential: Credential::OAuth(OAuth {
                    access_token: "token".into(),
                    headers: vec![header("ChatGPT-Account-ID", "account")].into(),
                }),
                session_id: Some("session"),
                want: vec![
                    header("Authorization", "Bearer token"),
                    header("ChatGPT-Account-ID", "account"),
                    header("originator", "example"),
                    header("Accept-Language", "en"),
                    header("accept-language", "es"),
                    header("session-id", "session"),
                ],
            },
            // A keyless route writes the pinned header and nothing else.
            Case {
                name: "keyless route",
                route: Route {
                    base_url: "http://127.0.0.1:11434/v1".into(),
                    headers: vec![header("x-note", "local")].into(),
                    ..Route::default()
                },
                credential: Credential::None,
                session_id: None,
                want: vec![header("x-note", "local")],
            },
        ];
        for case in cases {
            let head = built(
                &case.route,
                Protocol::AnthropicMessages,
                &case.credential,
                case.session_id,
            );
            assert_eq!(head.headers, case.want.as_slice(), "case: {}", case.name);
        }
    }

    #[test]
    fn session_header_per_route() {
        let codex = Route {
            base_url: "https://chatgpt.com/backend-api/codex".into(),
            session_header: SessionHeader::SessionId,
            ..Route::default()
        };
        let carried = built(
            &codex,
            Protocol::OpenaiResponses,
            &Credential::None,
            Some("0123456789abcdef"),
        );
        assert_eq!(carried.headers, [header("session-id", "0123456789abcdef")].as_slice());

        // The header follows the host, not the protocol: OpenCode reads it on every path it serves.
        for protocol in [
            Protocol::AnthropicMessages,
            Protocol::OpenaiChat,
            Protocol::OpenaiResponses,
        ] {
            let opencode = Route {
                base_url: "https://opencode.ai/zen/v1".into(),
                session_header: SessionHeader::XOpencodeSession,
                ..Route::default()
            };
            let sent = built(&opencode, protocol, &Credential::None, Some("0123456789abcdef"));
            assert_eq!(
                sent.headers,
                [header("x-opencode-session", "0123456789abcdef")].as_slice()
            );
        }

        // The public Responses endpoint routes on the body key, so a header there would be dead weight.
        let standard = Route {
            base_url: "https://api.openai.com/v1".into(),
            ..Route::default()
        };
        let plain = built(
            &standard,
            Protocol::OpenaiResponses,
            &Credential::None,
            Some("0123456789abcdef"),
        );
        assert_eq!(plain.headers, []);

        // A caller that names no session leaves the header off rather than sending an empty one.
        let absent = built(&codex, Protocol::OpenaiResponses, &Credential::None, None);
        assert_eq!(absent.headers, []);

        let empty = built(&codex, Protocol::OpenaiResponses, &Credential::None, Some(""));
        assert_eq!(empty.headers, [header("session-id", "")].as_slice());
    }

    #[test]
    fn trailing_slash_keeps_one_path_separator() {
        let route = Route {
            base_url: "https://api.anthropic.com/v1/".into(),
            ..Route::default()
        };
        let head = built(&route, Protocol::AnthropicMessages, &Credential::None, None);
        assert_eq!(head.url, "https://api.anthropic.com/v1/messages");
    }

    // Configuration can give a route that breaks these rules, so the encoder returns an error.
    #[test]
    fn rejects_credential_mismatch_and_invalid_headers() {
        let keyed = Route {
            base_url: "https://h/v1".into(),
            credential_header: Some(CredentialHeader::XApiKey),
            ..Route::default()
        };
        let mismatch = try_build(&keyed, Protocol::OpenaiChat, &Credential::None, None);
        assert_same(mismatch.err(), Some(EncodeError::CredentialMismatch));
        let broken = [header("bad name", "x")];
        let route = Route {
            base_url: "https://h/v1".into(),
            headers: broken.to_vec().into(),
            ..Route::default()
        };
        assert_same(
            try_build(&route, Protocol::OpenaiChat, &Credential::None, None).err(),
            Some(invalid("bad name")),
        );
        let owned = [header("User-Agent", "other")];
        let route = Route {
            base_url: "https://h/v1".into(),
            headers: owned.to_vec().into(),
            ..Route::default()
        };
        assert_same(
            try_build(&route, Protocol::OpenaiChat, &Credential::None, None).err(),
            Some(invalid("User-Agent")),
        );
        let session = Route {
            base_url: "https://h/v1".into(),
            session_header: SessionHeader::SessionId,
            ..Route::default()
        };
        let control = try_build(&session, Protocol::OpenaiChat, &Credential::None, Some("a\r\nb"));
        assert_same(control.err(), Some(invalid("session-id")));
    }

    // A header value can be a credential, so the error names the header and prints the name escaped.
    #[test]
    fn invalid_header_error_names_the_header_and_never_the_value() {
        let keyed = Route {
            base_url: "https://h/v1".into(),
            credential_header: Some(CredentialHeader::XApiKey),
            ..Route::default()
        };
        let error = try_build(
            &keyed,
            Protocol::AnthropicMessages,
            &Credential::ApiKey("sk-secret\n".into()),
            None,
        )
        .err();
        assert!(!error.clone().unwrap().to_string().contains("sk-secret"));
        assert_same(error, Some(invalid("x-api-key")));
        assert_eq!(
            invalid("a\r\nb").to_string(),
            r#"the request header "a\r\nb" is invalid"#,
        );

        // A bad value names its own header. With two bad headers, the identity header comes first.
        let bad_identity = [header("ChatGPT-Account-ID", "a\nb")];
        let grant = Credential::OAuth(OAuth {
            access_token: "t".into(),
            headers: bad_identity.to_vec().into(),
        });
        let bad_route = [header("x-note", "a\0b")];
        let bearer = Route {
            base_url: "https://h/v1".into(),
            credential_header: Some(CredentialHeader::AuthorizationBearer),
            headers: bad_route.to_vec().into(),
            ..Route::default()
        };
        let error = try_build(&bearer, Protocol::OpenaiChat, &grant, None).err();
        assert_same(error, Some(invalid("ChatGPT-Account-ID")));
        let key = Credential::ApiKey("k".into());
        let error = try_build(&bearer, Protocol::OpenaiChat, &key, None).err();
        assert_same(error, Some(invalid("x-note")));
    }

    // A gateway can choose either value when a credential or session name appears twice.
    #[test]
    fn rejects_repeated_credential_and_session_headers() {
        let repeat_key = [header("X-API-Key", "other")];
        let keyed = Route {
            base_url: "https://h/v1".into(),
            credential_header: Some(CredentialHeader::XApiKey),
            headers: repeat_key.to_vec().into(),
            ..Route::default()
        };
        let key = Credential::ApiKey("k".into());
        let repeated = try_build(&keyed, Protocol::AnthropicMessages, &key, None);
        assert_same(repeated.err(), Some(invalid("X-API-Key")));

        let repeat_auth = [header("authorization", "Bearer other")];
        let grant = Credential::OAuth(OAuth {
            access_token: "t".into(),
            headers: repeat_auth.to_vec().into(),
        });
        let bearer = Route {
            base_url: "https://h/v1".into(),
            credential_header: Some(CredentialHeader::AuthorizationBearer),
            ..Route::default()
        };
        let repeated = try_build(&bearer, Protocol::OpenaiChat, &grant, None);
        assert_same(repeated.err(), Some(invalid("authorization")));

        let repeat_session = [header("Session-Id", "s0")];
        let session = Route {
            base_url: "https://h/v1".into(),
            session_header: SessionHeader::SessionId,
            headers: repeat_session.to_vec().into(),
            ..Route::default()
        };
        let repeated = try_build(&session, Protocol::OpenaiResponses, &Credential::None, Some("s1"));
        assert_same(repeated.err(), Some(invalid("Session-Id")));
        // With no session id, the encoder writes no session header, so the pinned one is the only copy.
        let pinned = built(&session, Protocol::OpenaiResponses, &Credential::None, None);
        assert_eq!(pinned.headers, [header("Session-Id", "s0")].as_slice());

        // A route with no credential header may carry its own credential field.
        let own = [header("Authorization", "Bearer own")];
        let open = Route {
            base_url: "https://h/v1".into(),
            headers: own.to_vec().into(),
            ..Route::default()
        };
        let own = built(&open, Protocol::OpenaiChat, &Credential::None, None);
        assert_eq!(own.headers, [header("Authorization", "Bearer own")].as_slice());
    }

    // The encoder keeps one head, so the second request must show only its own headers.
    #[test]
    fn reused_head_writes_only_current_headers() {
        let first = [header("x-a", "1"), header("x-b", "2"), header("x-c", "3")];
        let second = [header("x-d", "4")];
        let mut head = HeadText::default();
        for (headers, want) in [(&first[..], &first[..]), (&second, &second), (&first, &first)] {
            let route = Route {
                base_url: "https://h/v1".into(),
                headers: headers.to_vec().into(),
                ..Route::default()
            };
            let target = Target {
                model: "m".into(),
                route,
                credential: Credential::None,
                wire: Wire::OpenaiChat(ChatWire::default()),
                tool_search: false,
            };
            head.build(&target, None).unwrap();
            assert_eq!(head.headers, want);
        }
    }
}
