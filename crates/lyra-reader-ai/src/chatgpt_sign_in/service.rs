use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use ureq::http::Uri;

use crate::openai::{CancellationToken, ClientConfig, RequestSpec, Transport, UreqTransport};

use super::{
    AuthorizationCode, ClientId, SignInError, VerifiedIdentity, encode_fields, verify_id_token,
};

const TOKEN_URL: &str = "https://auth.openai.com/api/accounts/oauth/token";
const DISCOVERY_URL: &str = "https://auth.openai.com/.well-known/openid-configuration";
const MODELS_URL: &str = "https://api.openai.com/v1/models";
const AUTH_HOST: &str = "auth.openai.com";
const RESOURCE: &str = "https://api.openai.com/v1";
const MAX_RESPONSE_BYTES: usize = 128 * 1024;
// The account catalog includes model metadata beyond the fields used by the picker.
// Keep token/discovery limits small without imposing them on this larger response.
const MAX_MODEL_CATALOG_BYTES: usize = 4 * 1024 * 1024;
const MAX_CREDENTIAL_BYTES: usize = 64 * 1024;

/// Kept in memory or in the platform vault. Do not place this record in preferences.
#[derive(Serialize, Deserialize)]
pub struct Credential {
    access_token: String,
    refresh_token: String,
    id_token: String,
    expires_at_unix: u64,
    scopes: Vec<String>,
}

impl Credential {
    pub fn access_token(&self) -> &str {
        &self.access_token
    }

    pub fn expires_at_unix(&self) -> u64 {
        self.expires_at_unix
    }

    fn permission_still_granted(&self) -> bool {
        ["resource.invoke", "chatgpt.tokens.use.direct"]
            .into_iter()
            .all(|scope| self.scopes.iter().any(|granted| granted == scope))
    }
}

pub struct ValidatedSignIn {
    pub client_id: super::ClientId,
    pub identity: VerifiedIdentity,
    pub credential: Credential,
}

#[derive(Serialize)]
pub struct CatalogModel {
    pub id: String,
    pub name: String,
}

#[derive(Deserialize)]
struct Catalog {
    models: Vec<ModelEntry>,
}

#[derive(Deserialize)]
struct ModelEntry {
    visibility: Option<String>,
    slug: Option<String>,
    display_name: Option<String>,
}

/// Catalog reads use the fixed model endpoint after the required scopes were granted.
pub fn models(
    credential: &Credential,
    cancel: &CancellationToken,
) -> Result<Vec<CatalogModel>, SignInError> {
    let transport = UreqTransport::system(ClientConfig {
        max_time: Duration::from_secs(30),
        ..ClientConfig::default()
    });
    models_with(&transport, credential, cancel)
}

fn models_with(
    transport: &dyn Transport,
    credential: &Credential,
    cancel: &CancellationToken,
) -> Result<Vec<CatalogModel>, SignInError> {
    if !valid_token(credential.access_token()) || !credential.permission_still_granted() {
        return Err(SignInError::PermissionMissing);
    }
    let bytes = request(
        transport,
        "GET",
        MODELS_URL,
        Vec::new(),
        Some(credential.access_token()),
        cancel,
    )?;
    listed_models(&bytes)
}

fn listed_models(bytes: &[u8]) -> Result<Vec<CatalogModel>, SignInError> {
    let catalog: Catalog =
        serde_json::from_slice(bytes).map_err(|_| SignInError::InvalidModelCatalog)?;
    Ok(catalog
        .models
        .into_iter()
        .filter_map(|entry| {
            let id = entry.slug?;
            let name = entry.display_name?;
            if entry.visibility.as_deref() == Some("list")
                && !id.is_empty()
                && id.len() <= 128
                && id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
                && !name.is_empty()
                && name.len() <= 240
                && !name.chars().any(char::is_control)
            {
                return Some(CatalogModel { id, name });
            }
            None
        })
        .collect())
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: String,
    id_token: String,
    token_type: String,
    expires_in: u64,
    scope: String,
}

impl TokenResponse {
    fn credential(self, now_unix: u64) -> Result<Credential, SignInError> {
        if !self.token_type.eq_ignore_ascii_case("bearer")
            || self.expires_in == 0
            || ![&self.access_token, &self.refresh_token, &self.id_token]
                .into_iter()
                .all(|token| valid_token(token))
        {
            return Err(SignInError::InvalidResponse);
        }
        let scopes: Vec<_> = self
            .scope
            .split_ascii_whitespace()
            .map(str::to_owned)
            .collect();
        if !["resource.invoke", "chatgpt.tokens.use.direct"]
            .into_iter()
            .all(|scope| scopes.iter().any(|granted| granted == scope))
        {
            return Err(SignInError::PermissionMissing);
        }
        Ok(Credential {
            access_token: self.access_token,
            refresh_token: self.refresh_token,
            id_token: self.id_token,
            expires_at_unix: now_unix
                .checked_add(self.expires_in)
                .ok_or(SignInError::InvalidResponse)?,
            scopes,
        })
    }
}

fn valid_token(token: &str) -> bool {
    !token.is_empty()
        && token.len() <= MAX_CREDENTIAL_BYTES
        && token.bytes().all(|byte| byte.is_ascii_graphic())
}

/// System trust roots, no redirects, and fixed official endpoints. This function belongs on the
/// explicit user sign-in worker. It does not publish credentials before identity verification.
pub fn exchange(
    grant: AuthorizationCode,
    cancel: &CancellationToken,
) -> Result<ValidatedSignIn, SignInError> {
    let transport = UreqTransport::system(ClientConfig {
        max_time: Duration::from_secs(30),
        ..ClientConfig::default()
    });
    exchange_with(&transport, grant, cancel, || {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs())
            .map_err(|_| SignInError::InvalidIdentity)
    })
}

fn now_unix() -> Result<u64, SignInError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|_| SignInError::InvalidIdentity)
}

#[derive(Deserialize)]
struct RefreshResponse {
    access_token: String,
    refresh_token: Option<String>,
    token_type: String,
    expires_in: u64,
    scope: Option<String>,
}

fn apply_refresh(
    credential: Credential,
    response: RefreshResponse,
    timestamp: u64,
) -> Result<Credential, SignInError> {
    let refresh_token = response.refresh_token.unwrap_or(credential.refresh_token);
    if !response.token_type.eq_ignore_ascii_case("bearer")
        || response.expires_in == 0
        || !valid_token(&response.access_token)
        || !valid_token(&refresh_token)
    {
        return Err(SignInError::InvalidResponse);
    }
    let updated = Credential {
        access_token: response.access_token,
        refresh_token,
        id_token: credential.id_token,
        expires_at_unix: timestamp
            .checked_add(response.expires_in)
            .ok_or(SignInError::InvalidResponse)?,
        scopes: response
            .scope
            .as_deref()
            .map(|value| value.split_ascii_whitespace().map(str::to_owned).collect())
            .unwrap_or(credential.scopes),
    };
    if !updated.permission_still_granted() {
        return Err(SignInError::PermissionMissing);
    }
    Ok(updated)
}

/// Refresh the grant for its issued client. Platform owners serialize per account
/// and must store the complete replacement before using its access token.
pub fn refresh(
    client: &ClientId,
    credential: Credential,
    cancel: &CancellationToken,
) -> Result<Credential, SignInError> {
    if !valid_token(&credential.refresh_token) || !credential.permission_still_granted() {
        return Err(SignInError::PermissionMissing);
    }
    let transport = UreqTransport::system(ClientConfig {
        max_time: Duration::from_secs(30),
        ..ClientConfig::default()
    });
    let form = encode_fields(&[
        ("grant_type", "refresh_token"),
        ("client_id", client.as_str()),
        ("refresh_token", &credential.refresh_token),
        ("resource", RESOURCE),
    ]);
    let bytes = request(
        &transport,
        "POST",
        TOKEN_URL,
        form.into_bytes(),
        None,
        cancel,
    )?;
    let response: RefreshResponse =
        serde_json::from_slice(&bytes).map_err(|_| SignInError::InvalidResponse)?;
    apply_refresh(credential, response, now_unix()?)
}

/// Revoke only the stored renewable session at this issuer's reported endpoint.
pub fn revoke(
    client: &ClientId,
    credential: &Credential,
    cancel: &CancellationToken,
) -> Result<(), SignInError> {
    if !valid_token(&credential.refresh_token) {
        return Err(SignInError::InvalidResponse);
    }
    let transport = UreqTransport::system(ClientConfig {
        max_time: Duration::from_secs(20),
        ..ClientConfig::default()
    });
    let discovery = request(&transport, "GET", DISCOVERY_URL, Vec::new(), None, cancel)?;
    let metadata: Discovery =
        serde_json::from_slice(&discovery).map_err(|_| SignInError::InvalidResponse)?;
    let endpoint = verify_provider_url(
        metadata
            .revocation_endpoint
            .as_deref()
            .ok_or(SignInError::InvalidResponse)?,
    )?;
    let form = encode_fields(&[
        ("token", &credential.refresh_token),
        ("token_type_hint", "refresh_token"),
        ("client_id", client.as_str()),
    ]);
    request(
        &transport,
        "POST",
        endpoint,
        form.into_bytes(),
        None,
        cancel,
    )?;
    Ok(())
}

fn exchange_with(
    transport: &dyn Transport,
    grant: AuthorizationCode,
    cancel: &CancellationToken,
    now: impl Fn() -> Result<u64, SignInError>,
) -> Result<ValidatedSignIn, SignInError> {
    let form = grant.exchange_form().into_bytes();
    let payload = request(transport, "POST", TOKEN_URL, form, None, cancel)?;
    let tokens: TokenResponse =
        serde_json::from_slice(&payload).map_err(|_| SignInError::InvalidResponse)?;
    let credential = tokens.credential(now()?)?;
    let discovery = request(transport, "GET", DISCOVERY_URL, Vec::new(), None, cancel)?;
    let metadata: Discovery =
        serde_json::from_slice(&discovery).map_err(|_| SignInError::InvalidResponse)?;
    let key_url = verify_provider_url(&metadata.jwks_uri)?;
    let jwks = request(transport, "GET", key_url, Vec::new(), None, cancel)?;
    let checked_at = now()?;
    let identity = verify_id_token(&credential.id_token, &jwks, &grant, checked_at)?;
    if credential.expires_at_unix <= checked_at {
        return Err(SignInError::InvalidResponse);
    }
    if cancel.is_cancelled() {
        return Err(SignInError::Cancelled);
    }
    Ok(ValidatedSignIn {
        client_id: grant.client().clone(),
        identity,
        credential,
    })
}

#[derive(Deserialize)]
struct Discovery {
    jwks_uri: String,
    revocation_endpoint: Option<String>,
}

fn verify_provider_url(address: &str) -> Result<&str, SignInError> {
    if address.len() > 2048 {
        return Err(SignInError::InvalidResponse);
    }
    let uri: Uri = address.parse().map_err(|_| SignInError::InvalidResponse)?;
    if uri.scheme_str() != Some("https")
        || !uri
            .authority()
            .is_some_and(|host| host.as_str() == AUTH_HOST)
        || !uri.path().starts_with('/')
        || address.contains('#')
    {
        return Err(SignInError::InvalidResponse);
    }
    Ok(address)
}

fn request(
    transport: &dyn Transport,
    method: &'static str,
    address: &str,
    body: Vec<u8>,
    bearer: Option<&str>,
    cancel: &CancellationToken,
) -> Result<Vec<u8>, SignInError> {
    let mut headers = vec![("Accept".to_owned(), "application/json".to_owned())];
    if method == "POST" {
        headers.push((
            "Content-Type".to_owned(),
            "application/x-www-form-urlencoded".to_owned(),
        ));
    }
    if let Some(bearer) = bearer {
        headers.push(("Authorization".to_owned(), format!("Bearer {bearer}")));
    }
    let spec = RequestSpec {
        url: address.to_owned(),
        method,
        headers,
        body,
        is_local: false,
    };
    let mut response = transport
        .execute(&spec, cancel)
        .map_err(|_| service_failure(cancel))?;
    let status = response.status();
    let mut bytes = Vec::new();
    let limit = if address == MODELS_URL {
        MAX_MODEL_CATALOG_BYTES
    } else {
        MAX_RESPONSE_BYTES
    };
    while let Some(chunk) = response.next_chunk().map_err(|_| service_failure(cancel))? {
        if chunk.len() > limit - bytes.len() {
            return Err(if address == MODELS_URL {
                SignInError::ModelCatalogTooLarge
            } else {
                SignInError::InvalidResponse
            });
        }
        bytes.extend_from_slice(&chunk);
    }
    if !(200..300).contains(&status) {
        if serde_json::from_slice::<TokenError>(&bytes)
            .is_ok_and(|error| error.error == "invalid_grant")
        {
            return Err(SignInError::InvalidGrant);
        }
        return Err(SignInError::ServiceStatus(status));
    }
    Ok(bytes)
}

#[derive(Deserialize)]
struct TokenError {
    error: String,
}

fn service_failure(cancel: &CancellationToken) -> SignInError {
    if cancel.is_cancelled() {
        SignInError::Cancelled
    } else {
        SignInError::ServiceUnavailable
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::num::NonZeroU16;
    use std::sync::Mutex;

    use serde_json::{Value, json};

    use crate::openai::ResponseStream;
    use crate::provider::AiError;

    use super::super::{Registration, SignInAttempt};
    use super::*;

    struct Reply {
        method: &'static str,
        uri: &'static str,
        status: u16,
        body: Option<Vec<u8>>,
    }

    impl ResponseStream for Reply {
        fn status(&self) -> u16 {
            self.status
        }

        fn reason(&self) -> &str {
            ""
        }

        fn headers(&self) -> &[(String, String)] {
            &[]
        }

        fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, AiError> {
            Ok(self.body.take())
        }
    }

    struct Playback(Mutex<VecDeque<Reply>>);

    impl Playback {
        fn new(replies: impl IntoIterator<Item = Reply>) -> Self {
            Self(Mutex::new(replies.into_iter().collect()))
        }

        fn empty(&self) -> bool {
            self.0.lock().unwrap().is_empty()
        }
    }

    impl Transport for Playback {
        fn execute(
            &self,
            spec: &RequestSpec,
            _cancel: &CancellationToken,
        ) -> Result<Box<dyn ResponseStream>, AiError> {
            let reply = self
                .0
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected HTTP request");
            assert_eq!(reply.uri, spec.url);
            assert_eq!(reply.method, spec.method);
            if spec.method == "POST" {
                let body = std::str::from_utf8(&spec.body).unwrap();
                assert!(body.contains("grant_type=authorization_code"));
                assert!(body.contains("code=synthetic"));
                assert!(
                    body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A43120%2Fauth%2Fcallback")
                );
            } else if spec.url == MODELS_URL {
                assert!(spec.body.is_empty());
                assert!(
                    spec.headers
                        .iter()
                        .any(|(name, value)| name == "Authorization"
                            && value == "Bearer synthetic-access")
                );
            } else {
                assert!(
                    spec.body.is_empty()
                        && !spec.headers.iter().any(|(name, _)| name == "Authorization")
                );
            }
            Ok(Box::new(reply))
        }
    }

    fn reply(method: &'static str, uri: &'static str, value: Value) -> Reply {
        Reply {
            method,
            uri,
            status: 200,
            body: Some(serde_json::to_vec(&value).unwrap()),
        }
    }

    fn proof() -> AuthorizationCode {
        let (mut attempt, _) = SignInAttempt::with_secrets(
            NonZeroU16::new(43120).unwrap(),
            "urn:uuid:synthetic",
            Registration::New,
            "one-state".into(),
            "one-nonce".into(),
            "attempt-verifier".into(),
        )
        .unwrap();
        attempt
            .verify_callback(
                "/auth/callback?state=one-state&code=synthetic&client_id=oaiapp_synthetic",
            )
            .unwrap()
    }

    fn token_fixture() -> (Value, Value) {
        let page: Value = serde_json::from_str(include_str!(
            "../../tests/fixtures/chatgpt-sign-in-synthetic.json"
        ))
        .unwrap();
        let tokens = json!({
            "access_token": "synthetic-access",
            "refresh_token": "synthetic-refresh",
            "id_token": page["valid"],
            "token_type": "Bearer",
            "scope": "openid resource.invoke chatgpt.tokens.use.direct",
            "expires_in": 3000
        });
        (tokens, page["jwks"].clone())
    }

    #[test]
    fn catalog_keeps_listed_models_without_exposing_hidden_entries() {
        let result = listed_models(
            br#"{"models":[
            {"visibility":"hidden"},
            {"visibility":"list","slug":"missing-name"},
            {"visibility":"list","slug":"retained-v1","display_name":"Retained"},
            {"visibility":"list","slug":"bad/identifier","display_name":"Excluded"}
        ]}"#,
        )
        .unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].id, "retained-v1");
        assert_eq!(result[0].name, "Retained");
    }

    #[test]
    fn account_catalog_has_its_own_bounded_response_budget() {
        let (tokens, _) = token_fixture();
        let credential = || {
            serde_json::from_value::<TokenResponse>(tokens.clone())
                .unwrap()
                .credential(100)
                .unwrap()
        };
        let mut model_reply = reply(
            "GET",
            MODELS_URL,
            json!({
                "models":[{"visibility":"list","slug":"synthetic-model","display_name":"Synthetic model"}],
                "metadata":"x".repeat(MAX_RESPONSE_BYTES)
            }),
        );
        assert!(model_reply.body.as_ref().unwrap().len() > MAX_RESPONSE_BYTES);
        model_reply
            .body
            .as_mut()
            .unwrap()
            .resize(MAX_MODEL_CATALOG_BYTES, b' ');
        let mock = Playback::new([model_reply]);
        let models = models_with(&mock, &credential(), &CancellationToken::new()).unwrap();
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, "synthetic-model");
        assert!(mock.empty());

        let mut oversized = reply("GET", MODELS_URL, json!({"models":[]}));
        oversized
            .body
            .as_mut()
            .unwrap()
            .resize(MAX_MODEL_CATALOG_BYTES + 1, b' ');
        let mock = Playback::new([oversized]);
        assert_eq!(
            models_with(&mock, &credential(), &CancellationToken::new()).err(),
            Some(SignInError::ModelCatalogTooLarge)
        );
        assert!(mock.empty());

        let mut oversized_token = reply("POST", TOKEN_URL, tokens);
        oversized_token
            .body
            .as_mut()
            .unwrap()
            .resize(MAX_RESPONSE_BYTES + 1, b' ');
        let mock = Playback::new([oversized_token]);
        assert_eq!(
            exchange_with(&mock, proof(), &CancellationToken::new(), || Ok(100)).err(),
            Some(SignInError::InvalidResponse)
        );
        assert!(mock.empty());
    }

    #[test]
    fn malformed_catalog_is_reported_after_sign_in_without_echoing_payload() {
        let (tokens, _) = token_fixture();
        let credential = serde_json::from_value::<TokenResponse>(tokens)
            .unwrap()
            .credential(100)
            .unwrap();
        for payload in [
            json!({"models":null}),
            json!({"unexpected":"SYNTHETIC_PRIVATE_RESPONSE"}),
            json!({"models":[{"visibility":"list","slug":3,"display_name":"Synthetic"}]}),
        ] {
            let mock = Playback::new([reply("GET", MODELS_URL, payload)]);
            let error = models_with(&mock, &credential, &CancellationToken::new())
                .err()
                .unwrap();
            assert_eq!(error, SignInError::InvalidModelCatalog);
            assert_eq!(
                error.to_string(),
                "ChatGPT returned an invalid model catalog."
            );
            assert!(mock.empty());
        }
        let unauthorized = Credential {
            scopes: vec!["openid".into()],
            ..credential
        };
        let mock = Playback::new([]);
        assert_eq!(
            models_with(&mock, &unauthorized, &CancellationToken::new()).err(),
            Some(SignInError::PermissionMissing)
        );
        assert!(mock.empty());
    }

    #[test]
    fn refresh_preserves_identity_and_requires_the_granted_scopes() {
        let (tokens, _) = token_fixture();
        let credential = || {
            serde_json::from_value::<TokenResponse>(tokens.clone())
                .unwrap()
                .credential(100)
                .unwrap()
        };
        let response = |scope| RefreshResponse {
            access_token: "renewed-access".into(),
            refresh_token: Some("rotated-refresh".into()),
            token_type: "Bearer".into(),
            expires_in: 600,
            scope,
        };
        let updated = apply_refresh(credential(), response(None), 300).unwrap();
        assert_eq!(updated.access_token, "renewed-access");
        assert_eq!(updated.refresh_token, "rotated-refresh");
        assert_eq!(updated.id_token, credential().id_token);
        assert_eq!(updated.expires_at_unix, 900);
        assert_eq!(
            apply_refresh(credential(), response(Some("resource.invoke".into())), 300).err(),
            Some(SignInError::PermissionMissing)
        );
    }

    #[test]
    fn publishes_only_verified_identity_and_granted_plan_usage() {
        let (tokens, keys) = token_fixture();
        let key_url = "https://auth.openai.com/.well-known/jwks.json";
        let mock = Playback::new([
            reply("POST", TOKEN_URL, tokens),
            reply("GET", DISCOVERY_URL, json!({ "jwks_uri": key_url })),
            reply("GET", key_url, keys),
        ]);
        let result = exchange_with(&mock, proof(), &CancellationToken::new(), || Ok(100)).unwrap();
        assert_eq!(result.client_id.as_str(), "oaiapp_synthetic");
        assert_eq!(result.identity.subject, "synthetic-reader");
        assert_eq!(result.credential.access_token(), "synthetic-access");
        assert_eq!(result.credential.expires_at_unix(), 3100);
        assert!(mock.empty());
    }

    #[test]
    fn stops_before_untrusted_discovery_and_before_unauthorized_publication() {
        let (tokens, _) = token_fixture();
        let mock = Playback::new([
            reply("POST", TOKEN_URL, tokens.clone()),
            reply(
                "GET",
                DISCOVERY_URL,
                json!({ "jwks_uri": "https://auth.openai.com@elsewhere.example.invalid/jwks" }),
            ),
        ]);
        let error = exchange_with(&mock, proof(), &CancellationToken::new(), || Ok(100)).err();
        assert_eq!(error, Some(SignInError::InvalidResponse));
        assert!(mock.empty());

        let mut tokens = tokens;
        tokens["scope"] = json!("resource.invoke");
        let mock = Playback::new([reply("POST", TOKEN_URL, tokens)]);
        let error = exchange_with(&mock, proof(), &CancellationToken::new(), || Ok(100)).err();
        assert_eq!(error, Some(SignInError::PermissionMissing));
        assert!(mock.empty());
    }
}
