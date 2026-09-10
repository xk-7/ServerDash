//! A real loopback SSH/SFTP peer with deterministic test-only host keys.
//! No external daemon, account, private key, or network service is required.
use russh::{server, Channel, ChannelId, Pty};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{
        atomic::{AtomicU8, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tokio::{net::TcpListener, task::JoinHandle};
use tokio_util::sync::CancellationToken;

mod sftp;

pub const PASSWORD: &str = "loopback test password";
pub const USER: &str = "serverdash-test";
pub const GREETING: &[u8] = b"ready\r\n";
pub const BULK_SIZE: usize = 12 * 16384;

#[derive(Default)]
pub struct State {
    pub key_seed: AtomicU8,
    pub active_connections: AtomicUsize,
    pub authentication_attempts: AtomicUsize,
    pub sizes: Mutex<Vec<(u32, u32)>>,
    pub files: Arc<Mutex<HashMap<String, Vec<u8>>>>,
}

pub struct TestServer {
    pub address: SocketAddr,
    pub state: Arc<State>,
    cancellation: CancellationToken,
    task: JoinHandle<()>,
}

impl TestServer {
    pub async fn start() -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind loopback SSH server");
        let address = listener.local_addr().unwrap();
        let state = Arc::new(State::default());
        state.key_seed.store(7, Ordering::Release);
        let cancellation = CancellationToken::new();
        let task_state = state.clone();
        let cancel = cancellation.clone();
        let task = tokio::spawn(async move {
            loop {
                let (stream, _) = tokio::select! {
                    incoming = listener.accept() => incoming.unwrap(),
                    _ = cancel.cancelled() => break,
                };
                let key = russh::keys::ssh_key::private::Ed25519Keypair::from_seed(
                    &[task_state.key_seed.load(Ordering::Acquire); 32],
                );
                let config = Arc::new(server::Config {
                    keys: vec![key.into()],
                    auth_rejection_time: Duration::from_millis(1),
                    auth_rejection_time_initial: Some(Duration::ZERO),
                    inactivity_timeout: Some(Duration::from_secs(15)),
                    ..Default::default()
                });
                task_state.active_connections.fetch_add(1, Ordering::AcqRel);
                let handler = Peer {
                    state: task_state.clone(),
                    channels: HashMap::new(),
                };
                let child_cancel = cancel.clone();
                tokio::spawn(async move {
                    if let Ok(mut running) = server::run_stream(config, stream, handler).await {
                        let handle = running.handle();
                        tokio::select! {
                            _ = &mut running => {},
                            _ = child_cancel.cancelled() => {
                                let _ = handle.disconnect(russh::Disconnect::ByApplication, "Test cleanup".into(), "en".into()).await;
                                let _ = tokio::time::timeout(Duration::from_secs(1), running).await;
                            },
                        }
                    }
                });
            }
        });
        Self {
            address,
            state,
            cancellation,
            task,
        }
    }

    pub fn rotate_key(&self) {
        self.state.key_seed.fetch_add(1, Ordering::AcqRel);
    }

    pub async fn assert_disconnected(&self) {
        tokio::time::timeout(Duration::from_secs(3), async {
            while self.state.active_connections.load(Ordering::Acquire) != 0 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("SSH peer remained alive after cancellation or close");
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.cancellation.cancel();
        self.task.abort();
    }
}

struct Peer {
    state: Arc<State>,
    channels: HashMap<ChannelId, Channel<server::Msg>>,
}

impl Drop for Peer {
    fn drop(&mut self) {
        self.state.active_connections.fetch_sub(1, Ordering::AcqRel);
    }
}

impl server::Handler for Peer {
    type Error = anyhow::Error;

    async fn auth_password(
        &mut self,
        user: &str,
        password: &str,
    ) -> Result<server::Auth, Self::Error> {
        self.state
            .authentication_attempts
            .fetch_add(1, Ordering::AcqRel);
        Ok(if user == USER && password == PASSWORD {
            server::Auth::Accept
        } else {
            server::Auth::reject()
        })
    }

    async fn channel_open_session(
        &mut self,
        channel: Channel<server::Msg>,
        reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.channels.insert(channel.id(), channel);
        reply.accept().await;
        Ok(())
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        _: &str,
        columns: u32,
        rows: u32,
        _: u32,
        _: u32,
        _: &[(Pty, u32)],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.state.sizes.lock().unwrap().push((columns, rows));
        session.channel_success(channel)?;
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        session.data(channel, GREETING.to_vec())?;
        Ok(())
    }

    async fn window_change_request(
        &mut self,
        _: ChannelId,
        columns: u32,
        rows: u32,
        _: u32,
        _: u32,
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.state.sizes.lock().unwrap().push((columns, rows));
        Ok(())
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        bytes: &[u8],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        if !self.channels.contains_key(&channel) {
            return Ok(());
        }
        match bytes {
            b"BULK" => {
                session.data(channel, vec![b'x'; BULK_SIZE])?;
            }
            b"EXIT" => {
                session.data(channel, b"last bytes\r\n".to_vec())?;
                session.exit_status_request(channel, 23)?;
                session.close(channel)?;
            }
            _ => {
                session.data(channel, bytes.to_vec())?;
            }
        }
        Ok(())
    }

    async fn subsystem_request(
        &mut self,
        channel_id: ChannelId,
        name: &str,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        if name == "sftp" {
            let channel = self
                .channels
                .remove(&channel_id)
                .expect("SFTP channel exists");
            session.channel_success(channel_id)?;
            let files = self.state.files.clone();
            tokio::spawn(async move {
                russh_sftp::server::run(channel.into_stream(), sftp::Peer::new(files)).await;
            });
        } else {
            session.channel_failure(channel_id)?;
        }
        Ok(())
    }
}
