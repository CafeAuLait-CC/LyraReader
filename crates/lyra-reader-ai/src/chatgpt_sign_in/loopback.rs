use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::num::NonZeroU16;
use std::thread;
use std::time::{Duration, Instant};

use crate::openai::CancellationToken;

use super::{AuthorizationCode, Registration, SignInAttempt, SignInError};

const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(300);
const CLIENT_TIMEOUT: Duration = Duration::from_secs(2);
const POLL_INTERVAL: Duration = Duration::from_millis(50);
const MAX_HEADERS: usize = 16 * 1024;

/// A short-lived callback server owned by the sign-in worker. It never listens on
/// a host interface or opens a browser.
pub struct LoopbackAuthorization {
    listener: TcpListener,
    attempt: SignInAttempt,
    host: String,
    deadline: Instant,
}

impl LoopbackAuthorization {
    /// Bind before asking the platform to open the returned authorization URL.
    pub fn begin(
        host_id: &str,
        registration: Registration<'_>,
    ) -> Result<(Self, String), SignInError> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .map_err(|_| SignInError::ListenerUnavailable)?;
        listener
            .set_nonblocking(true)
            .map_err(|_| SignInError::ListenerUnavailable)?;
        let port = NonZeroU16::new(
            listener
                .local_addr()
                .map_err(|_| SignInError::ListenerUnavailable)?
                .port(),
        )
        .ok_or(SignInError::ListenerUnavailable)?;
        let (attempt, url) = SignInAttempt::start(port, host_id, registration)?;
        Ok((
            Self {
                listener,
                attempt,
                host: format!("127.0.0.1:{port}"),
                deadline: Instant::now() + ATTEMPT_TIMEOUT,
            },
            url,
        ))
    }

    /// Blocks on the background worker, never the GUI thread. A malformed or
    /// mismatched callback does not terminate the browser's legitimate attempt.
    pub fn wait(mut self, cancel: &CancellationToken) -> Result<AuthorizationCode, SignInError> {
        loop {
            check_pending(cancel, self.deadline)?;
            let mut stream = match self.listener.accept() {
                Ok((stream, address)) if address.ip().is_loopback() => stream,
                Ok(_) => continue,
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    thread::sleep(POLL_INTERVAL);
                    continue;
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                Err(_) => return Err(SignInError::ListenerUnavailable),
            };
            let deadline = self.deadline.min(Instant::now() + CLIENT_TIMEOUT);
            let decision = read_target(&mut stream, &self.host, cancel, deadline)
                .and_then(|target| self.attempt.verify_callback(&target));
            match decision {
                Ok(grant) => {
                    check_pending(cancel, self.deadline)?;
                    write_answer(
                        &mut stream,
                        "200 OK",
                        "Return to LyraReader to finish signing in.",
                    );
                    return Ok(grant);
                }
                Err(SignInError::Declined) => {
                    write_answer(&mut stream, "200 OK", "You can return to LyraReader.");
                    return Err(SignInError::Declined);
                }
                Err(SignInError::Cancelled) => return Err(SignInError::Cancelled),
                Err(_) => write_answer(&mut stream, "400 Bad Request", "Invalid sign-in callback."),
            }
        }
    }
}

fn check_pending(cancel: &CancellationToken, deadline: Instant) -> Result<(), SignInError> {
    if cancel.is_cancelled() {
        return Err(SignInError::Cancelled);
    }
    if Instant::now() >= deadline {
        return Err(SignInError::TimedOut);
    }
    Ok(())
}

fn read_target(
    stream: &mut TcpStream,
    host: &str,
    cancel: &CancellationToken,
    deadline: Instant,
) -> Result<String, SignInError> {
    let invalid = SignInError::InvalidCallback;
    stream.set_nonblocking(false).map_err(|_| invalid)?;
    stream
        .set_read_timeout(Some(POLL_INTERVAL))
        .map_err(|_| invalid)?;
    stream
        .set_write_timeout(Some(POLL_INTERVAL))
        .map_err(|_| invalid)?;

    let mut bytes = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    loop {
        check_pending(cancel, deadline)?;
        match stream.read(&mut chunk) {
            Ok(0) => return Err(invalid),
            Ok(count) if count <= MAX_HEADERS - bytes.len() => {
                bytes.extend_from_slice(&chunk[..count]);
            }
            Ok(_) => return Err(invalid),
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::Interrupted | ErrorKind::WouldBlock | ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(_) => return Err(invalid),
        }

        let mut headers = [httparse::EMPTY_HEADER; 32];
        let mut request = httparse::Request::new(&mut headers);
        if request.parse(&bytes).map_err(|_| invalid)?.is_partial() {
            continue;
        }
        let mut hosts = request
            .headers
            .iter()
            .filter(|header| header.name.eq_ignore_ascii_case("host"));
        if request.method != Some("GET")
            || !hosts
                .next()
                .is_some_and(|header| header.value == host.as_bytes())
            || hosts.next().is_some()
        {
            return Err(invalid);
        }
        return Ok(request.path.ok_or(invalid)?.to_owned());
    }
}

fn write_answer(stream: &mut TcpStream, status: &str, message: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{message}",
        message.len()
    );
    // The browser may have navigated away. The authenticated callback is still valid.
    let _ = stream.write_all(response.as_bytes());
}
