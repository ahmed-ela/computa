//! Ordered NDJSON client. Mutating requests are never retried after uncertain delivery.
use computa_contracts::appserver::{RpcError, RpcId};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicI64, Ordering},
    },
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{Mutex, mpsc, oneshot},
};
use tokio_util::sync::CancellationToken;
const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
#[derive(Clone, Debug, thiserror::Error)]
pub enum ClientError {
    #[error("The Agent Runtime disconnected.")]
    Disconnected,
    #[error("The Agent Runtime sent an invalid NDJSON frame.")]
    InvalidFrame,
    #[error("The Agent Runtime request capacity has been reached.")]
    Capacity,
    #[error("{0}")]
    Server(#[from] RpcError),
    #[error("The Agent Runtime initialization timed out.")]
    Timeout,
    #[error("The qualification wire observer could not retain complete evidence.")]
    Observation,
}
#[derive(Clone, Debug)]
pub enum Incoming {
    Notification {
        method: String,
        params: Value,
    },
    Request {
        id: RpcId,
        method: String,
        params: Value,
    },
    Disconnected,
}
/// Direction at the NDJSON acceptance boundary. Outbound observation precedes
/// writing and is not proof of delivery or execution.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WireDirection {
    Inbound,
    Outbound,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WireObservationError {
    Capacity,
    Persistence,
    Rejected,
}
/// Native qualification seam, never exposed through UI actions. Frames are
/// borrowed transiently. Observers must persist only finite allowlisted fixture
/// metadata and digests, never bootstrap/configuration/authentication values or
/// existing private history. Returning an error stops delivery and the client;
/// callers must fail qualification rather than accepting partial evidence.
pub trait WireObserver: Send + Sync {
    fn observe(
        &self,
        direction: WireDirection,
        sequence: u64,
        frame: &Value,
    ) -> Result<(), WireObservationError>;
}
struct Observation {
    observer: Arc<dyn WireObserver>,
    sequence: StdMutex<u64>,
}
impl Observation {
    fn accept(&self, direction: WireDirection, frame: &Value) -> Result<(), ClientError> {
        let mut sequence = self.sequence.lock().map_err(|_| ClientError::Observation)?;
        *sequence = sequence.checked_add(1).ok_or(ClientError::Observation)?;
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            self.observer.observe(direction, *sequence, frame)
        }))
        .map_err(|_| ClientError::Observation)?
        .map_err(|_| ClientError::Observation)
    }
}
type Pending = HashMap<RpcId, oneshot::Sender<Result<Value, ClientError>>>;
pub struct RpcClient {
    writer: mpsc::Sender<Vec<u8>>,
    pending: Arc<Mutex<Pending>>,
    counter: AtomicI64,
    stop: CancellationToken,
}
impl RpcClient {
    pub fn attach<R, W>(reader: R, writer: W) -> (Arc<Self>, mpsc::Receiver<Incoming>)
    where
        R: AsyncRead + Send + Unpin + 'static,
        W: AsyncWrite + Send + Unpin + 'static,
    {
        Self::attach_observed(reader, writer, None)
    }
    pub fn attach_with_observer<R, W>(
        reader: R,
        writer: W,
        observer: Arc<dyn WireObserver>,
    ) -> (Arc<Self>, mpsc::Receiver<Incoming>)
    where
        R: AsyncRead + Send + Unpin + 'static,
        W: AsyncWrite + Send + Unpin + 'static,
    {
        Self::attach_observed(reader, writer, Some(observer))
    }
    fn attach_observed<R, W>(
        reader: R,
        writer: W,
        observer: Option<Arc<dyn WireObserver>>,
    ) -> (Arc<Self>, mpsc::Receiver<Incoming>)
    where
        R: AsyncRead + Send + Unpin + 'static,
        W: AsyncWrite + Send + Unpin + 'static,
    {
        let observation = observer.map(|observer| {
            Arc::new(Observation {
                observer,
                sequence: StdMutex::new(0),
            })
        });
        let failed_observation = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (writes, mut out) = mpsc::channel::<Vec<u8>>(64);
        let (events, input) = mpsc::channel(256);
        let pending = Arc::new(Mutex::new(HashMap::new()));
        let stop = CancellationToken::new();
        let client = Arc::new(Self {
            writer: writes,
            pending: pending.clone(),
            counter: AtomicI64::new(1),
            stop: stop.clone(),
        });
        let cancel = stop.clone();
        let outbound_observation = observation.clone();
        let outbound_failed = failed_observation.clone();
        tokio::spawn(async move {
            let mut writer = writer;
            loop {
                tokio::select! {_ = cancel.cancelled()=>break,data=out.recv()=>match data{Some(data)=>{
                    if let Some(observation) = &outbound_observation {
                        let accepted = computa_contracts::strict_json::parse(&data)
                            .map_err(|_| ClientError::InvalidFrame)
                            .and_then(|value| observation.accept(WireDirection::Outbound, &value));
                        if accepted.is_err() {
                            outbound_failed.store(true, Ordering::Release);
                            cancel.cancel();
                            break;
                        }
                    }
                    if writer.write_all(&data).await.is_err()||writer.flush().await.is_err(){cancel.cancel();break;}
                },None=>break}}
            }
            let _ = writer.shutdown().await;
        });
        tokio::spawn(async move {
            let result = read_loop(reader, &pending, &events, &stop, observation.as_deref()).await;
            stop.cancel();
            let error = if failed_observation.load(Ordering::Acquire) {
                ClientError::Observation
            } else {
                result.err().unwrap_or(ClientError::Disconnected)
            };
            let mut p = pending.lock().await;
            for (_, reply) in p.drain() {
                let _ = reply.send(Err(error.clone()));
            }
            drop(p);
            let _ = events.send(Incoming::Disconnected).await;
        });
        (client, input)
    }
    async fn send(&self, value: Value) -> Result<(), ClientError> {
        if self.stop.is_cancelled() {
            return Err(ClientError::Disconnected);
        }
        let mut bytes = serde_json::to_vec(&value).map_err(|_| ClientError::InvalidFrame)?;
        if bytes.len() > MAX_FRAME_BYTES {
            return Err(ClientError::InvalidFrame);
        }
        bytes.push(b'\n');
        self.writer
            .send(bytes)
            .await
            .map_err(|_| ClientError::Disconnected)
    }
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, ClientError> {
        let id = RpcId::Number(self.counter.fetch_add(1, Ordering::Relaxed));
        let (reply, result) = oneshot::channel();
        {
            let mut pending = self.pending.lock().await;
            if pending.len() >= 256 {
                return Err(ClientError::Capacity);
            }
            pending.insert(id.clone(), reply);
        }
        if let Err(e) = self
            .send(json!({"id":id,"method":method,"params":params}))
            .await
        {
            self.pending.lock().await.remove(&id);
            return Err(e);
        }
        result.await.map_err(|_| ClientError::Disconnected)?
    }
    pub async fn notify(&self, method: &str, params: Value) -> Result<(), ClientError> {
        self.send(json!({"method":method,"params":params})).await
    }
    pub async fn reply(
        &self,
        id: RpcId,
        result: Result<Value, RpcError>,
    ) -> Result<(), ClientError> {
        self.send(match result {
            Ok(value) => json!({"id":id,"result":value}),
            Err(e) => json!({"id":id,"error":e.to_value()}),
        })
        .await
    }
    pub async fn initialize(&self) -> Result<Value, ClientError> {
        let result=tokio::time::timeout(std::time::Duration::from_secs(30),self.request("initialize",json!({"clientInfo":{"name":"local_codex","title":"Computa","version":"0.1.0"},"capabilities":{"experimentalApi":true}}))).await.map_err(|_|ClientError::Timeout)??;
        self.notify("initialized", json!({})).await?;
        Ok(result)
    }
    pub fn close(&self) {
        self.stop.cancel();
    }
}
async fn read_loop<R: AsyncRead + Unpin>(
    mut reader: R,
    pending: &Mutex<Pending>,
    events: &mpsc::Sender<Incoming>,
    stop: &CancellationToken,
    observation: Option<&Observation>,
) -> Result<(), ClientError> {
    let mut buffer = Vec::new();
    let mut chunk = [0; 64 * 1024];
    loop {
        let n = tokio::select! {_ = stop.cancelled()=>return Ok(()),n=reader.read(&mut chunk)=>n.map_err(|_|ClientError::Disconnected)?};
        if n == 0 {
            return if buffer.iter().all(u8::is_ascii_whitespace) {
                Ok(())
            } else {
                Err(ClientError::InvalidFrame)
            };
        }
        buffer.extend_from_slice(&chunk[..n]);
        while let Some(end) = buffer.iter().position(|c| *c == b'\n') {
            if end > MAX_FRAME_BYTES {
                return Err(ClientError::InvalidFrame);
            }
            let frame: Vec<_> = buffer.drain(..=end).collect();
            let line = &frame[..frame.len() - 1];
            if line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            let value: Value = computa_contracts::strict_json::parse(line)
                .map_err(|_| ClientError::InvalidFrame)?;
            let o = value.as_object().ok_or(ClientError::InvalidFrame)?;
            if let Some(observation) = observation {
                observation.accept(WireDirection::Inbound, &value)?;
            }
            if let Some(method) = o.get("method") {
                let method = method.as_str().ok_or(ClientError::InvalidFrame)?.to_owned();
                let params = o.get("params").cloned().unwrap_or(Value::Null);
                let event = if let Some(id) = o.get("id") {
                    Incoming::Request {
                        id: serde_json::from_value(id.clone())
                            .map_err(|_| ClientError::InvalidFrame)?,
                        method,
                        params,
                    }
                } else {
                    Incoming::Notification { method, params }
                };
                events
                    .send(event)
                    .await
                    .map_err(|_| ClientError::Disconnected)?;
            } else {
                let id: RpcId =
                    serde_json::from_value(o.get("id").ok_or(ClientError::InvalidFrame)?.clone())
                        .map_err(|_| ClientError::InvalidFrame)?;
                let result = match (o.get("result"), o.get("error")) {
                    (Some(v), None) => Ok(v.clone()),
                    (None, Some(v)) => Err(ClientError::Server(
                        RpcError::from_value(v).ok_or(ClientError::InvalidFrame)?,
                    )),
                    _ => return Err(ClientError::InvalidFrame),
                };
                if let Some(reply) = pending.lock().await.remove(&id) {
                    let _ = reply.send(result);
                }
            }
        }
        if buffer.len() > MAX_FRAME_BYTES {
            return Err(ClientError::InvalidFrame);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, BufReader};
    #[tokio::test]
    async fn chunked_wire_order_and_server_ids_are_preserved() {
        let (client_stream, server_stream) = tokio::io::duplex(4096);
        let (r, w) = tokio::io::split(client_stream);
        let (client, mut incoming) = RpcClient::attach(r, w);
        let (sr, mut sw) = tokio::io::split(server_stream);
        tokio::spawn(async move {
            let mut lines = BufReader::new(sr).lines();
            let req: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            let reply = format!(
                "{{\"id\":{},\"result\":{{\"ok\":true}}}}\n{{\"id\":\"server-id\",\"method\":\"item/tool/call\",\"params\":{{}}}}\n",
                req["id"]
            );
            for c in reply.as_bytes().chunks(3) {
                sw.write_all(c).await.unwrap();
            }
            let reply: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(reply["id"], "server-id");
        });
        assert_eq!(client.request("test", json!({})).await.unwrap()["ok"], true);
        let Incoming::Request { id, .. } = incoming.recv().await.unwrap() else {
            panic!("expected server request")
        };
        client
            .reply(id, Ok(json!({"success":false})))
            .await
            .unwrap();
    }
    struct Capture {
        frames: StdMutex<Vec<(WireDirection, u64, Value)>>,
        reject: Option<WireDirection>,
    }
    impl WireObserver for Capture {
        fn observe(
            &self,
            direction: WireDirection,
            sequence: u64,
            frame: &Value,
        ) -> Result<(), WireObservationError> {
            if self.reject == Some(direction) {
                return Err(WireObservationError::Capacity);
            }
            self.frames
                .lock()
                .unwrap()
                .push((direction, sequence, frame.clone()));
            Ok(())
        }
    }
    #[tokio::test]
    async fn observer_preserves_exact_ids_frames_and_monotonic_order() {
        let capture = Arc::new(Capture {
            frames: StdMutex::new(Vec::new()),
            reject: None,
        });
        let (client_stream, server_stream) = tokio::io::duplex(4096);
        let (r, w) = tokio::io::split(client_stream);
        let (client, mut incoming) = RpcClient::attach_with_observer(r, w, capture.clone());
        let (sr, mut sw) = tokio::io::split(server_stream);
        let task = tokio::spawn(async move {
            let mut lines = BufReader::new(sr).lines();
            let request: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            sw.write_all(
                format!("{}\n", json!({"id":request["id"],"result":{"ok":true}})).as_bytes(),
            )
            .await
            .unwrap();
            sw.write_all(format!("{}\n", json!({"id":"call-7","method":"item/tool/call","params":{"turnId":"turn-3","arguments":{"x":4}}})).as_bytes()).await.unwrap();
            let reply: Value =
                serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
            assert_eq!(reply, json!({"id":"call-7","result":{"success":true}}));
        });
        client
            .request("turn/start", json!({"threadId":"thread-2"}))
            .await
            .unwrap();
        let Incoming::Request { id, .. } = incoming.recv().await.unwrap() else {
            panic!("request")
        };
        client.reply(id, Ok(json!({"success":true}))).await.unwrap();
        task.await.unwrap();
        let frames = capture.frames.lock().unwrap();
        assert_eq!(frames.len(), 4);
        assert_eq!(
            frames.iter().map(|(_, n, _)| *n).collect::<Vec<_>>(),
            [1, 2, 3, 4]
        );
        assert_eq!(frames[0].0, WireDirection::Outbound);
        assert_eq!(frames[2].0, WireDirection::Inbound);
        assert_eq!(frames[2].2["params"]["arguments"], json!({"x":4}));
        assert_eq!(frames[3].2["id"], "call-7");
        client.close();
    }
    #[tokio::test]
    async fn outbound_observer_failure_prevents_wire_delivery_and_fails_pending() {
        let capture = Arc::new(Capture {
            frames: StdMutex::new(Vec::new()),
            reject: Some(WireDirection::Outbound),
        });
        let (client_stream, mut server_stream) = tokio::io::duplex(4096);
        let (r, w) = tokio::io::split(client_stream);
        let (client, _) = RpcClient::attach_with_observer(r, w, capture);
        let error = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            client.request("turn/start", json!({})),
        )
        .await
        .unwrap()
        .unwrap_err();
        assert!(matches!(error, ClientError::Observation));
        let mut bytes = [0; 1024];
        assert_eq!(server_stream.read(&mut bytes).await.unwrap(), 0);
    }
    #[tokio::test]
    async fn inbound_observer_failure_never_dispatches_an_unretained_tool_call() {
        let capture = Arc::new(Capture {
            frames: StdMutex::new(Vec::new()),
            reject: Some(WireDirection::Inbound),
        });
        let (client_stream, mut server_stream) = tokio::io::duplex(4096);
        let (r, w) = tokio::io::split(client_stream);
        let (client, mut incoming) = RpcClient::attach_with_observer(r, w, capture);
        server_stream
            .write_all(b"{\"id\":\"unsafe-call\",\"method\":\"item/tool/call\",\"params\":{}}\n")
            .await
            .unwrap();
        assert!(matches!(
            tokio::time::timeout(std::time::Duration::from_secs(1), incoming.recv())
                .await
                .unwrap(),
            Some(Incoming::Disconnected)
        ));
        assert!(matches!(
            client.request("turn/start", json!({})).await,
            Err(ClientError::Disconnected)
        ));
    }
    #[test]
    fn remote_error_boolean_code_is_invalid_and_null_data_distinct() {
        assert!(RpcError::from_value(&json!({"code":true,"message":"x"})).is_none());
        let missing = RpcError::from_value(&json!({"code":-1,"message":"x"})).unwrap();
        let null = RpcError::from_value(&json!({"code":-1,"message":"x","data":null})).unwrap();
        assert_ne!(missing, null);
    }
}
