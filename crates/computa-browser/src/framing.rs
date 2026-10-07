use crate::BrowserError;
use computa_contracts::chrome::MAX_FRAME;
use std::io::{Read, Write};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
fn length(header: [u8; 4]) -> Result<usize, BrowserError> {
    let count = u32::from_le_bytes(header) as usize;
    if count == 0 || count > MAX_FRAME {
        Err(BrowserError::InvalidFrame)
    } else {
        Ok(count)
    }
}
pub fn read_frame(reader: &mut impl Read) -> Result<Option<Vec<u8>>, BrowserError> {
    let mut header = [0u8; 4];
    match reader.read(&mut header[..1]) {
        Ok(0) => return Ok(None),
        Ok(1) => {}
        _ => return Err(BrowserError::Closed),
    }
    reader
        .read_exact(&mut header[1..])
        .map_err(|_| BrowserError::Closed)?;
    let mut payload = vec![0; length(header)?];
    reader
        .read_exact(&mut payload)
        .map_err(|_| BrowserError::Closed)?;
    Ok(Some(payload))
}
pub fn write_frame(writer: &mut impl Write, payload: &[u8]) -> Result<(), BrowserError> {
    if payload.is_empty() || payload.len() > MAX_FRAME {
        return Err(BrowserError::InvalidFrame);
    }
    writer
        .write_all(&(payload.len() as u32).to_le_bytes())
        .map_err(|_| BrowserError::Closed)?;
    writer
        .write_all(payload)
        .map_err(|_| BrowserError::Closed)?;
    writer.flush().map_err(|_| BrowserError::Closed)
}
pub async fn read_async(
    reader: &mut (impl AsyncRead + Unpin),
) -> Result<Option<Vec<u8>>, BrowserError> {
    let mut header = [0u8; 4];
    match reader.read(&mut header[..1]).await {
        Ok(0) => return Ok(None),
        Ok(1) => {}
        _ => return Err(BrowserError::Closed),
    }
    reader
        .read_exact(&mut header[1..])
        .await
        .map_err(|_| BrowserError::Closed)?;
    let mut payload = vec![0; length(header)?];
    reader
        .read_exact(&mut payload)
        .await
        .map_err(|_| BrowserError::Closed)?;
    Ok(Some(payload))
}
pub async fn write_async(
    writer: &mut (impl AsyncWrite + Unpin),
    payload: &[u8],
) -> Result<(), BrowserError> {
    if payload.is_empty() || payload.len() > MAX_FRAME {
        return Err(BrowserError::InvalidFrame);
    }
    writer
        .write_all(&(payload.len() as u32).to_le_bytes())
        .await
        .map_err(|_| BrowserError::Closed)?;
    writer
        .write_all(payload)
        .await
        .map_err(|_| BrowserError::Closed)?;
    writer.flush().await.map_err(|_| BrowserError::Closed)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_empty_oversized_and_partial_frames() {
        for bytes in [
            vec![0, 0, 0, 0],
            (MAX_FRAME as u32 + 1).to_le_bytes().to_vec(),
            vec![1, 0],
            vec![3, 0, 0, 0, 1],
        ] {
            assert!(read_frame(&mut bytes.as_slice()).is_err());
        }
        assert_eq!(read_frame(&mut [].as_slice()).unwrap(), None);
    }
    #[test]
    fn exact_roundtrip() {
        let mut bytes = vec![];
        write_frame(&mut bytes, b"hello").unwrap();
        assert_eq!(&bytes[..4], &[5, 0, 0, 0]);
        assert_eq!(
            read_frame(&mut bytes.as_slice()).unwrap(),
            Some(b"hello".to_vec())
        );
    }
}
