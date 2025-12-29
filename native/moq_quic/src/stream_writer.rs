// Stream writer module for async QUIC stream writes
// Uses mpsc channels to buffer write operations from FFI

use quinn::{SendStream as QuinnSendStream, RecvStream as QuinnRecvStream};
use std::sync::Arc;
use tokio::sync::mpsc::{self, Sender};

/// Command for stream writer operations
pub enum StreamCommand {
    Write(Vec<u8>),
    Finish,
}

/// Stream writer that handles async writes via a channel
/// This allows FFI calls to queue writes without blocking
pub struct StreamWriter {
    tx: Sender<StreamCommand>,
}

impl StreamWriter {
    /// Create a new stream writer for Quinn streams
    pub fn new(
        session_id: u64,
        stream_id: u64,
        send_stream: QuinnSendStream,
        channel_capacity: usize,
    ) -> Self {
        let (tx, mut rx) = mpsc::channel(channel_capacity);

        // Spawn task to process write commands
        tokio::spawn(async move {
            let mut send_stream = send_stream;
            let mut finished = false;

            while !finished {
                match rx.recv().await {
                    Some(StreamCommand::Write(data)) => {
                        if let Err(e) = send_stream.write_all(&data).await {
                            log::error!("Failed to write to stream {} session {}: {:?}", stream_id, session_id, e);
                            break;
                        }
                    }
                    Some(StreamCommand::Finish) => {
                        if let Err(e) = send_stream.finish() {
                            log::warn!("Failed to finish stream {} session {}: {:?}", stream_id, session_id, e);
                        }
                        finished = true;
                    }
                    None => {
                        // Channel closed, clean up
                        break;
                    }
                }
            }
        });

        Self { tx }
    }

    /// Try to write data without blocking
    /// Returns error if channel is full or closed
    pub fn try_write(&self, data: Vec<u8>) -> Result<(), mpsc::error::TrySendError<StreamCommand>> {
        self.tx.try_send(StreamCommand::Write(data))
    }

    /// Try to finish the stream
    pub fn try_finish(&self) -> Result<(), mpsc::error::TrySendError<StreamCommand>> {
        self.tx.try_send(StreamCommand::Finish)
    }

    /// Finish the stream asynchronously (awaits completion)
    pub async fn finish(&self) -> Result<(), Box<dyn std::error::Error>> {
        self.tx.send(StreamCommand::Finish)
            .await
            .map_err(|e| format!("Failed to send finish command: {:?}", e))?;
        Ok(())
    }
}

/// Callback for receiving stream data
pub trait StreamDataCallback: Send + Sync {
    fn on_stream_data(&self, session_id: u64, stream_id: u64, data: &[u8]);
}

/// Handle a unidirectional stream with incremental reading
pub async fn handle_unidirectional_stream(
    session_id: u64,
    stream_id: u64,
    mut recv_stream: QuinnRecvStream,
    callback: Arc<dyn StreamDataCallback>,
) {
    let mut buffer = vec![0u8; 65536]; // 64KB read buffer

    loop {
        match recv_stream.read(&mut buffer).await {
            Ok(Some(len)) => {
                log::debug!("Uni stream {} received {} bytes", stream_id, len);
                callback.on_stream_data(session_id, stream_id, &buffer[..len]);
            }
            Ok(None) => {
                log::debug!("Uni stream {} closed", stream_id);
                break;
            }
            Err(e) => {
                log::error!("Error reading from uni stream {}: {:?}", stream_id, e);
                break;
            }
        }
    }
}

/// Handle a bidirectional stream with incremental reading
pub async fn handle_bidirectional_stream(
    session_id: u64,
    stream_id: u64,
    send_stream: QuinnSendStream,
    mut recv_stream: QuinnRecvStream,
    callback: Arc<dyn StreamDataCallback>,
    channel_capacity: usize,
) -> Arc<StreamWriter> {
    // Create stream writer for the send side
    let writer = Arc::new(StreamWriter::new(
        session_id,
        stream_id,
        send_stream,
        channel_capacity,
    ));

    // Clone for the receive task
    let writer_for_cleanup = writer.clone();

    // Spawn receive task
    tokio::spawn(async move {
        let mut buffer = vec![0u8; 65536]; // 64KB read buffer

        loop {
            match recv_stream.read(&mut buffer).await {
                Ok(Some(len)) => {
                    log::debug!("Bi stream {} received {} bytes", stream_id, len);
                    callback.on_stream_data(session_id, stream_id, &buffer[..len]);
                }
                Ok(None) => {
                    log::debug!("Bi stream {} receive side closed", stream_id);
                    break;
                }
                Err(e) => {
                    log::error!("Error reading from bi stream {}: {:?}", stream_id, e);
                    break;
                }
            }
        }

        // Clean up writer when receive side closes
        if let Err(e) = writer_for_cleanup.finish().await {
            log::warn!("Failed to finish stream writer for stream {}: {:?}", stream_id, e);
        }
    });

    writer
}
