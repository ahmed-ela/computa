//! Safe file boundary for offscreen benchmark-only rendering and recognition.
use super::*;
use serde_json::json;
#[cfg(target_os = "macos")]
pub fn render_fixtures(fixtures: &Path, output: &Path) -> Result<Value> {
    let output = private_output(output)?;
    let raw = read(fixtures)?;
    let decoded = parse(&raw)?;
    let rows = computa_macos::benchmark_image::render(&decoded)
        .map_err(|_| BenchmarkError("native_fixture_render_failed"))?;
    let mut names = vec![];
    for row in rows {
        let name = format!("{}.png", row.name);
        super::opaque::write_new(&output, &name, &row.png)?;
        names.push(row.name);
    }
    Ok(
        json!({"output":output,"rendered":names,"sourceSHA256":hash(raw),"renderer":"computa-rust-offscreen","width":1000,"height":650,"noDesktopCapture":true}),
    )
}
#[cfg(not(target_os = "macos"))]
pub fn render_fixtures(_fixtures: &Path, _output: &Path) -> Result<Value> {
    Err(BenchmarkError("native_image_requires_macos"))
}
#[cfg(target_os = "macos")]
pub fn native_ocr(input: &Path, output: &Path, cpu_only: bool) -> Result<Value> {
    ensure(output.is_absolute(), "absolute_output_path_required")?;
    let parent = output
        .parent()
        .ok_or(BenchmarkError("invalid_output_path"))?;
    private_output(parent)?;
    ensure(!output.exists(), "new_output_file_required")?;
    let bytes = read_bounded(input, 32 * 1024 * 1024)?;
    ensure(
        !bytes.is_empty() && bytes.len() <= 32 * 1024 * 1024,
        "native_png_byte_bound",
    )?;
    // This function is exclusively a standalone benchmark executable entrypoint.
    // The process guard covers Vision calls that ignore cooperative cancellation.
    let (done, wait) = std::sync::mpsc::channel::<()>();
    let deadline = std::thread::Builder::new()
        .name("benchmark-ocr-deadline".into())
        .spawn(move || {
            if matches!(
                wait.recv_timeout(std::time::Duration::from_secs(60)),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout)
            ) {
                std::process::exit(124);
            }
        })
        .map_err(|_| BenchmarkError("native_ocr_deadline_unavailable"))?;
    let result = computa_macos::benchmark_image::recognize_png(&bytes, cpu_only);
    let _ = done.send(());
    let _ = deadline.join();
    let result = result.map_err(|_| BenchmarkError("native_ocr_failed_redacted"))?;
    let encoded =
        serde_json::to_vec_pretty(&result).map_err(|_| BenchmarkError("json_encode_failed"))?;
    ensure(encoded.len() <= 128 * 1024, "native_ocr_output_bound")?;
    let name = output
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or(BenchmarkError("invalid_output_path"))?;
    super::opaque::write_new(parent, name, &encoded)?;
    Ok(result)
}
#[cfg(not(target_os = "macos"))]
pub fn native_ocr(_input: &Path, _output: &Path, _cpu_only: bool) -> Result<Value> {
    Err(BenchmarkError("native_image_requires_macos"))
}
pub fn format_ocr_files(ocr: &Path, source: &Path, output: &Path) -> Result<Value> {
    ensure(output.is_absolute(), "absolute_output_path_required")?;
    let raw = read_json(ocr)?;
    let source: OcrSource = serde_json::from_value(read_json(source)?)
        .map_err(|_| BenchmarkError("invalid_ocr_source"))?;
    let text = format_ocr(&raw, &source, 1536)?;
    let parent = output
        .parent()
        .ok_or(BenchmarkError("invalid_output_path"))?;
    private_output(parent)?;
    let name = output
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or(BenchmarkError("invalid_output_path"))?;
    super::opaque::write_new(parent, name, text.as_bytes())?;
    Ok(json!({"output":output,"bytes":text.len()}))
}
