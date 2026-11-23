use std::io::{Read, Write};
use std::net::{Ipv4Addr, TcpStream};
use std::thread;
use std::time::Duration;

use lyra_reader_ai::chatgpt_sign_in::{LoopbackAuthorization, Registration, SignInError};
use lyra_reader_ai::openai::CancellationToken;
use percent_encoding::percent_decode_str;

fn address_and_state(url: &str) -> (u16, String) {
    let (_, query) = url.split_once('?').unwrap();
    let fields = query
        .split('&')
        .filter_map(|part| part.split_once('='))
        .collect::<std::collections::BTreeMap<_, _>>();
    let redirect = percent_decode_str(fields["redirect_uri"])
        .decode_utf8()
        .unwrap();
    let port = redirect
        .strip_prefix("http://127.0.0.1:")
        .unwrap()
        .strip_suffix("/auth/callback")
        .unwrap()
        .parse()
        .unwrap();
    (port, fields["state"].to_owned())
}

fn send(port: u16, method: &str, host: &str, target: &str) -> String {
    let mut browser = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
    browser
        .set_read_timeout(Some(Duration::from_secs(4)))
        .unwrap();
    let request = format!("{method} {target} HTTP/1.1\r\nHost: {host}\r\n\r\n");
    browser.write_all(request.as_bytes()).unwrap();
    let mut reply = String::new();
    browser.read_to_string(&mut reply).unwrap();
    reply
}

#[test]
fn only_the_loopback_host_and_pending_state_consume_the_code() {
    let (callback, url) =
        LoopbackAuthorization::begin("urn:uuid:synthetic", Registration::New).unwrap();
    let (port, state) = address_and_state(&url);
    let host = format!("127.0.0.1:{port}");
    let wait = thread::spawn(move || callback.wait(&CancellationToken::new()));
    let target = format!("/auth/callback?code=bound&client_id=oaiapp_synthetic&state={state}");
    assert!(send(port, "POST", &host, &target).starts_with("HTTP/1.1 400 "));
    assert!(send(port, "GET", "other.example.invalid", &target).starts_with("HTTP/1.1 400 "));
    assert!(send(port, "GET", &host, "/auth/callback?state=other").starts_with("HTTP/1.1 400 "));
    assert!(send(port, "GET", &host, &target).starts_with("HTTP/1.1 200 "));
    let grant = wait.join().unwrap().unwrap();
    assert!(grant.exchange_form().contains("code=bound"));
    assert!(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).is_err());
}

#[test]
fn cancel_retires_the_loopback_listener_even_with_a_partial_connection() {
    let (callback, url) =
        LoopbackAuthorization::begin("urn:uuid:synthetic", Registration::New).unwrap();
    let (port, _) = address_and_state(&url);
    let cancel = CancellationToken::new();
    let worker_cancel = cancel.clone();
    let wait = thread::spawn(move || callback.wait(&worker_cancel));
    let mut browser = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
    browser.write_all(b"GET /auth/call").unwrap();
    cancel.cancel();
    assert_eq!(wait.join().unwrap().err(), Some(SignInError::Cancelled));
    assert!(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).is_err());
}
