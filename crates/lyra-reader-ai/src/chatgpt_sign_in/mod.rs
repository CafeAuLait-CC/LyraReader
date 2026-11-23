//! The public Sign in with ChatGPT authorization-code handshake.
//!
//! The browser and system credential store belong to the platform. This module
//! builds the fixed requests and keeps the proof for one loopback callback.

use std::fmt;
use std::num::NonZeroU16;

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use percent_encoding::{AsciiSet, NON_ALPHANUMERIC, percent_decode_str, utf8_percent_encode};
use ring::rand::{SecureRandom, SystemRandom};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

mod identity;
mod loopback;
mod service;
pub use identity::{VerifiedIdentity, verify_id_token};
pub use loopback::LoopbackAuthorization;
pub use service::{CatalogModel, Credential, ValidatedSignIn, exchange, models, refresh, revoke};

const AUTHORIZE: &str = "https://auth.openai.com/api/accounts/authorize";
const RESOURCE: &str = "https://api.openai.com/v1";
const CALLBACK_PATH: &str = "/auth/callback";
const NEW_CLIENT: &str = "dynamic_agent_client";
const SCOPE: &str = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
const MAX_CALLBACK_TARGET: usize = 8192;
const FORM_ENCODE: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

/// The issued value is an identifier, separate from the access and refresh tokens.
#[derive(Clone, PartialEq, Eq)]
pub struct ClientId(String);

impl ClientId {
    pub fn parse(value: &str) -> Result<Self, SignInError> {
        if value.is_empty()
            || value.len() > 256
            || value == NEW_CLIENT
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        {
            return Err(SignInError::InvalidClientId);
        }
        Ok(Self(value.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

pub enum Registration<'a> {
    New,
    Reuse {
        issued_id: &'a ClientId,
        email: Option<&'a str>,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignInError {
    Randomness,
    HostId,
    InvalidCallback,
    StateMismatch,
    Declined,
    MissingCode,
    InvalidClientId,
    Completed,
    InvalidIdentity,
    ListenerUnavailable,
    Cancelled,
    TimedOut,
    InvalidResponse,
    PermissionMissing,
    InvalidGrant,
    ServiceUnavailable,
    ServiceStatus(u16),
}

impl fmt::Display for SignInError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::Randomness => "Could not create secure sign-in parameters.",
            Self::HostId => "The sign-in host identifier is invalid.",
            Self::InvalidCallback => "ChatGPT returned an invalid sign-in callback.",
            Self::StateMismatch => "Sign-in state did not match the pending attempt.",
            Self::Declined => "ChatGPT sign-in was declined or cancelled.",
            Self::MissingCode => "The sign-in callback is incomplete.",
            Self::InvalidClientId => "The sign-in callback has an invalid client registration.",
            Self::Completed => "This sign-in attempt has already ended.",
            Self::InvalidIdentity => "The ChatGPT identity token could not be verified.",
            Self::ListenerUnavailable => "Could not start the local ChatGPT sign-in callback.",
            Self::Cancelled => "Sign-in cancelled.",
            Self::TimedOut => "ChatGPT sign-in timed out. Please try again.",
            Self::InvalidResponse => "ChatGPT returned an invalid sign-in response.",
            Self::PermissionMissing => {
                "ChatGPT plan usage was not enabled. Sign in again and approve plan usage."
            }
            Self::InvalidGrant => {
                "The sign-in code expired or was already used. Try signing in again."
            }
            Self::ServiceUnavailable => "Could not reach the ChatGPT sign-in service.",
            Self::ServiceStatus(status) => {
                return write!(
                    formatter,
                    "The ChatGPT sign-in service returned HTTP {status}."
                );
            }
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for SignInError {}

/// One proof bundle. It intentionally has no Debug implementation or serialization.
pub struct SignInAttempt {
    proof: Option<CallbackProof>,
}

struct CallbackProof {
    state: String,
    nonce: String,
    verifier: String,
    redirect: String,
    expected_client: Option<ClientId>,
}

pub struct AuthorizationCode {
    client: ClientId,
    code: String,
    nonce: String,
    verifier: String,
    redirect: String,
}

impl SignInAttempt {
    pub fn start(
        port: NonZeroU16,
        host_id: &str,
        registration: Registration<'_>,
    ) -> Result<(Self, String), SignInError> {
        let random = SystemRandom::new();
        let fresh = || -> Result<String, SignInError> {
            let mut bytes = [0u8; 32];
            random
                .fill(&mut bytes)
                .map_err(|_| SignInError::Randomness)?;
            Ok(URL_SAFE_NO_PAD.encode(bytes))
        };
        Self::with_secrets(port, host_id, registration, fresh()?, fresh()?, fresh()?)
    }

    fn with_secrets(
        port: NonZeroU16,
        host_id: &str,
        registration: Registration<'_>,
        state: String,
        nonce: String,
        verifier: String,
    ) -> Result<(Self, String), SignInError> {
        if host_id.is_empty()
            || host_id.len() > 256
            || !host_id.bytes().all(|byte| byte.is_ascii_graphic())
        {
            return Err(SignInError::HostId);
        }

        let redirect = format!("http://127.0.0.1:{port}{CALLBACK_PATH}");
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let expected_client = match &registration {
            Registration::New => None,
            Registration::Reuse { issued_id, .. } => Some((*issued_id).clone()),
        };
        let mut fields = vec![
            (
                "client_id",
                expected_client
                    .as_ref()
                    .map_or(NEW_CLIENT, ClientId::as_str),
            ),
            ("ext_agent_host_id", host_id),
            ("response_type", "code"),
            ("redirect_uri", &redirect),
            ("scope", SCOPE),
            ("resource", RESOURCE),
            ("state", &state),
            ("nonce", &nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", &challenge),
        ];
        match registration {
            Registration::New => fields.push(("agent_name_hint", "LyraReader")),
            Registration::Reuse {
                email: Some(email), ..
            } if !email.is_empty() && email.len() <= 320 => {
                fields.push(("login_hint", email));
            }
            Registration::Reuse { .. } => {}
        }
        let url = format!("{AUTHORIZE}?{}", encode_fields(&fields));
        Ok((
            Self {
                proof: Some(CallbackProof {
                    state,
                    nonce,
                    verifier,
                    redirect,
                    expected_client,
                }),
            },
            url,
        ))
    }

    /// Validate the exact request target after the listener checks the method,
    /// loopback destination and bounded HTTP headers.
    pub fn verify_callback(&mut self, target: &str) -> Result<AuthorizationCode, SignInError> {
        let proof = self.proof.as_ref().ok_or(SignInError::Completed)?;
        let fields = CallbackFields::decode(target)?;
        let supplied_state = fields.state.ok_or(SignInError::StateMismatch)?;
        if !bool::from(supplied_state.as_bytes().ct_eq(proof.state.as_bytes())) {
            return Err(SignInError::StateMismatch);
        }
        if fields.error.is_some() {
            self.proof = None;
            return Err(SignInError::Declined);
        }

        let code = fields
            .code
            .filter(|code| !code.is_empty() && code.bytes().all(|byte| byte.is_ascii_graphic()))
            .ok_or(SignInError::MissingCode)?;
        let callback_client = fields.client.as_deref().map(ClientId::parse).transpose()?;
        let client = match (proof.expected_client.as_ref(), callback_client) {
            (Some(expected), Some(client)) if *expected != client => {
                return Err(SignInError::InvalidClientId);
            }
            (Some(expected), _) => expected.clone(),
            (None, Some(client)) => client,
            (None, None) => return Err(SignInError::InvalidClientId),
        };
        let proof = self.proof.take().ok_or(SignInError::Completed)?;
        Ok(AuthorizationCode {
            client,
            code,
            nonce: proof.nonce,
            verifier: proof.verifier,
            redirect: proof.redirect,
        })
    }
}

impl AuthorizationCode {
    /// The exact form is carried only in memory to the token endpoint.
    pub fn exchange_form(&self) -> String {
        encode_fields(&[
            ("grant_type", "authorization_code"),
            ("client_id", self.client.as_str()),
            ("code", &self.code),
            ("code_verifier", &self.verifier),
            ("redirect_uri", &self.redirect),
            ("resource", RESOURCE),
        ])
    }

    /// Bind ID-token validation to the nonce from the same attempt.
    pub fn nonce(&self) -> &str {
        &self.nonce
    }

    /// Registration from the validated callback, independent of account identity.
    pub fn client(&self) -> &ClientId {
        &self.client
    }
}

fn encode_fields(fields: &[(&str, &str)]) -> String {
    fields
        .iter()
        .map(|(key, value)| format!("{key}={}", utf8_percent_encode(value, FORM_ENCODE)))
        .collect::<Vec<_>>()
        .join("&")
}

#[derive(Default)]
struct CallbackFields {
    state: Option<String>,
    code: Option<String>,
    client: Option<String>,
    error: Option<String>,
}

impl CallbackFields {
    fn decode(target: &str) -> Result<Self, SignInError> {
        if target.len() > MAX_CALLBACK_TARGET || target.contains('#') {
            return Err(SignInError::InvalidCallback);
        }
        let query = target
            .strip_prefix(CALLBACK_PATH)
            .and_then(|value| value.strip_prefix('?'))
            .ok_or(SignInError::InvalidCallback)?;
        let mut fields = Self::default();
        for entry in query.split('&') {
            let (key, value) = entry.split_once('=').ok_or(SignInError::InvalidCallback)?;
            let key = decode_field(key)?;
            let slot = match key.as_str() {
                "state" => &mut fields.state,
                "code" => &mut fields.code,
                "client_id" => &mut fields.client,
                "error" => &mut fields.error,
                _ => continue,
            };
            if slot.is_some() {
                return Err(SignInError::InvalidCallback);
            }
            *slot = Some(decode_field(value)?);
        }
        Ok(fields)
    }
}

fn decode_field(raw: &str) -> Result<String, SignInError> {
    let mut bytes = raw.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'%'
            && !(bytes.next().is_some_and(|byte| byte.is_ascii_hexdigit())
                && bytes.next().is_some_and(|byte| byte.is_ascii_hexdigit()))
        {
            return Err(SignInError::InvalidCallback);
        }
    }
    let form_value = raw.replace('+', " ");
    let decoded = percent_decode_str(&form_value)
        .decode_utf8()
        .map_err(|_| SignInError::InvalidCallback)?;
    if decoded.chars().any(char::is_control) {
        return Err(SignInError::InvalidCallback);
    }
    Ok(decoded.into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_VERIFIER: &str = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

    fn fixture(registration: Registration<'_>) -> (SignInAttempt, String) {
        SignInAttempt::with_secrets(
            NonZeroU16::new(43120).unwrap(),
            "urn:uuid:synthetic-host",
            registration,
            "one-state".into(),
            "one-nonce".into(),
            TEST_VERIFIER.into(),
        )
        .unwrap()
    }

    #[test]
    fn registration_and_exchange_bind_exact_redirect_and_pkce() {
        let (mut attempt, url) = fixture(Registration::New);
        assert!(url.starts_with("https://auth.openai.com/api/accounts/authorize?"));
        assert!(url.contains("agent_name_hint=LyraReader"));
        assert!(url.contains("client_id=dynamic_agent_client"));
        assert!(url.contains("code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"));
        let callback =
            "/auth/callback?state=one-state&code=fixture%2Fcode%2Bvalue&client_id=oaiapp_synthetic";
        let grant = attempt.verify_callback(callback).unwrap();
        let redirect = "redirect_uri=http%3A%2F%2F127.0.0.1%3A43120%2Fauth%2Fcallback";
        assert!(url.contains(redirect));
        assert!(grant.exchange_form().contains(redirect));
        assert!(
            grant
                .exchange_form()
                .contains("code=fixture%2Fcode%2Bvalue")
        );
        assert!(
            grant
                .exchange_form()
                .contains(&format!("code_verifier={TEST_VERIFIER}"))
        );
        assert_eq!(grant.nonce(), "one-nonce");
        assert_eq!(grant.client().as_str(), "oaiapp_synthetic");
        assert_eq!(
            attempt.verify_callback(callback).err(),
            Some(SignInError::Completed)
        );
    }

    #[test]
    fn reuse_never_changes_client_identity() {
        let client = ClientId::parse("oaiapp_saved").unwrap();
        let (mut attempt, url) = fixture(Registration::Reuse {
            issued_id: &client,
            email: Some("synthetic@example.invalid"),
        });
        assert!(url.contains("client_id=oaiapp_saved"));
        assert!(url.contains("login_hint=synthetic%40example.invalid"));
        assert!(!url.contains("agent_name_hint"));
        assert_eq!(
            attempt
                .verify_callback("/auth/callback?state=one-state&code=value&client_id=oaiapp_other")
                .err(),
            Some(SignInError::InvalidClientId)
        );
        let grant = attempt
            .verify_callback("/auth/callback?state=one-state&code=value")
            .unwrap();
        assert_eq!(grant.client().as_str(), client.as_str());
    }

    #[test]
    fn denied_or_mismatched_callbacks_do_not_exchange_codes() {
        let (mut attempt, _) = fixture(Registration::New);
        assert_eq!(
            attempt
                .verify_callback("/auth/callback?state=wrong&error=access_denied")
                .err(),
            Some(SignInError::StateMismatch)
        );
        assert_eq!(
            attempt
                .verify_callback("/auth/callback?state=one-state&error=access_denied&code=ignored")
                .err(),
            Some(SignInError::Declined)
        );
        assert_eq!(
            attempt
                .verify_callback("/auth/callback?state=one-state&code=value&client_id=oaiapp_saved")
                .err(),
            Some(SignInError::Completed)
        );
    }

    #[test]
    fn callback_rejects_alternate_path_ambiguous_fields_and_malformed_encoding() {
        let (mut attempt, _) = fixture(Registration::New);
        for invalid in [
            "/callback?state=one-state&code=value",
            "/auth/callback/extra?state=one-state&code=value",
            "/auth/callback?state=one-state&s%74ate=wrong&code=value",
            "/auth/callback?state=one-state&code=%E1%01&client_id=oaiapp_saved",
            "/auth/callback?state=one-state&code=bad%u0&client_id=oaiapp_saved",
            "/auth/callback?state=one-state&code=bad%0A&client_id=oaiapp_saved",
            "/auth/callback?state=one-state&code=value#fragment",
        ] {
            assert_eq!(
                attempt.verify_callback(invalid).err(),
                Some(SignInError::InvalidCallback)
            );
        }
        assert_eq!(
            attempt
                .verify_callback(
                    "/auth/callback?state=one-state&code=value&client_id=dynamic_agent_client"
                )
                .err(),
            Some(SignInError::InvalidClientId)
        );
    }

    #[test]
    fn signed_identity_requires_all_attempt_claims_and_an_unambiguous_key() {
        let (mut attempt, _) = fixture(Registration::New);
        let grant = attempt
            .verify_callback(
                "/auth/callback?state=one-state&code=synthetic&client_id=oaiapp_synthetic",
            )
            .unwrap();
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/chatgpt-sign-in-synthetic.json"
        ))
        .unwrap();
        let tokens = fixture["untrusted"].as_array().unwrap();
        let good = fixture["valid"].as_str().unwrap();
        let jwks = serde_json::to_vec(&fixture["jwks"]).unwrap();
        let identity = verify_id_token(good, &jwks, &grant, 100).unwrap();
        assert_eq!(identity.subject, "synthetic-reader");
        assert_eq!(identity.email.as_deref(), Some("reader@example.invalid"));
        for invalid in tokens {
            assert_eq!(
                verify_id_token(invalid.as_str().unwrap(), &jwks, &grant, 100).err(),
                Some(SignInError::InvalidIdentity)
            );
        }
        assert_eq!(
            verify_id_token(good, &jwks, &grant, 200).err(),
            Some(SignInError::InvalidIdentity)
        );

        let mut damaged = good.as_bytes().to_owned();
        let last = damaged.last_mut().unwrap();
        *last = if *last == b'A' { b'B' } else { b'A' };
        assert_eq!(
            verify_id_token(&String::from_utf8(damaged).unwrap(), &jwks, &grant, 100).err(),
            Some(SignInError::InvalidIdentity)
        );

        let mut ambiguous = fixture["jwks"].clone();
        let keys = ambiguous["keys"].as_array_mut().unwrap();
        keys.push(keys[0].clone());
        let ambiguous = serde_json::to_vec(&ambiguous).unwrap();
        assert_eq!(
            verify_id_token(good, &ambiguous, &grant, 100).err(),
            Some(SignInError::InvalidIdentity)
        );
    }
}
