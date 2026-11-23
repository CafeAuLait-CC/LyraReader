use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::signature::{RSA_PKCS1_2048_8192_SHA256, RsaPublicKeyComponents};
use serde::Deserialize;

use super::{AuthorizationCode, SignInError};

const ISSUER: &str = "https://auth.openai.com";
const MAX_ID_TOKEN_BYTES: usize = 64 * 1024;
const MAX_JWKS_BYTES: usize = 128 * 1024;
const MAX_KEYS: usize = 64;

#[derive(Deserialize)]
struct Header {
    alg: String,
    kid: String,
    #[serde(default)]
    crit: Vec<String>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Audience {
    One(String),
    Many(Vec<String>),
}

#[derive(Deserialize)]
struct Claims {
    iss: String,
    sub: String,
    aud: Audience,
    azp: Option<String>,
    exp: u64,
    nbf: Option<u64>,
    nonce: String,
    email: Option<String>,
}

#[derive(Deserialize)]
struct Keys {
    keys: Vec<Jwk>,
}

#[derive(Deserialize)]
struct Jwk {
    kid: Option<String>,
    kty: String,
    alg: Option<String>,
    #[serde(rename = "use")]
    usage: Option<String>,
    n: Option<String>,
    e: Option<String>,
}

/// Display metadata is only released after the signature and request binding are verified.
#[derive(Clone, PartialEq, Eq)]
pub struct VerifiedIdentity {
    pub subject: String,
    pub email: Option<String>,
}

pub fn verify_id_token(
    token: &str,
    jwks: &[u8],
    grant: &AuthorizationCode,
    now_unix: u64,
) -> Result<VerifiedIdentity, SignInError> {
    let invalid = SignInError::InvalidIdentity;
    if token.len() > MAX_ID_TOKEN_BYTES || jwks.len() > MAX_JWKS_BYTES {
        return Err(invalid);
    }
    let (signed, signature) = token.rsplit_once('.').ok_or(invalid)?;
    let (header, claims) = signed.split_once('.').ok_or(invalid)?;
    let header: Header = serde_json::from_slice(&decode(header)?).map_err(|_| invalid)?;
    if header.alg != "RS256" || !header.crit.is_empty() || !valid_identity_text(&header.kid) {
        return Err(invalid);
    }

    let keys: Keys = serde_json::from_slice(jwks).map_err(|_| invalid)?;
    if keys.keys.len() > MAX_KEYS {
        return Err(invalid);
    }
    let mut matching = keys
        .keys
        .iter()
        .filter(|key| key.kid.as_ref() == Some(&header.kid));
    let key = matching.next().ok_or(invalid)?;
    if matching.next().is_some()
        || key.kty != "RSA"
        || key.alg.as_deref().is_some_and(|alg| alg != "RS256")
        || key.usage.as_deref().is_some_and(|usage| usage != "sig")
    {
        return Err(invalid);
    }
    let n = decode(key.n.as_deref().ok_or(invalid)?)?;
    let e = decode(key.e.as_deref().ok_or(invalid)?)?;
    let signature = decode(signature)?;
    RsaPublicKeyComponents { n, e }
        .verify(&RSA_PKCS1_2048_8192_SHA256, signed.as_bytes(), &signature)
        .map_err(|_| invalid)?;

    let claims: Claims = serde_json::from_slice(&decode(claims)?).map_err(|_| invalid)?;
    let expected_audience = grant.client().as_str();
    let audience_matches = match &claims.aud {
        Audience::One(client) => client == expected_audience,
        Audience::Many(clients) => {
            clients.iter().any(|client| client == expected_audience)
                && (clients.len() == 1 || claims.azp.as_deref() == Some(expected_audience))
        }
    };
    if claims.iss != ISSUER
        || !audience_matches
        || claims
            .azp
            .as_deref()
            .is_some_and(|client| client != expected_audience)
        || claims.exp <= now_unix
        || claims.nbf.is_some_and(|time| time > now_unix)
        || claims.nonce != grant.nonce()
        || !valid_identity_text(&claims.sub)
    {
        return Err(invalid);
    }
    Ok(VerifiedIdentity {
        subject: claims.sub,
        email: claims.email.filter(|email| valid_identity_text(email)),
    })
}

fn decode(value: &str) -> Result<Vec<u8>, SignInError> {
    URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| SignInError::InvalidIdentity)
}

fn valid_identity_text(value: &str) -> bool {
    !value.is_empty() && value.len() <= 320 && !value.chars().any(char::is_control)
}
