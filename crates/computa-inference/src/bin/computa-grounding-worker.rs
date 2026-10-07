//! Private stdio model worker. The native model and Metal allocations never
//! cross threads; cancellation destroys only this app-owned process group.
use base64::{Engine, engine::general_purpose::STANDARD};
use computa_contracts::grounding::{
    self as wire, CaptureBinding, ModelName, RefusalCode, Request, Response,
};
use computa_inference::grounding_backend::{
    GroundingError, GroundingReply, VerifiedGroundingInstallation,
};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    io::{self, Read, Write},
    path::PathBuf,
    time::{Duration, Instant},
};
use uuid::Uuid;

struct Options {
    root: PathBuf,
    parent: i32,
    instance: Uuid,
}
fn options() -> Result<Options, &'static str> {
    let mut root = None;
    let mut parent = None;
    let mut seen = HashSet::new();
    let mut args = std::env::args_os().skip(1);
    while let Some(flag) = args.next() {
        if !seen.insert(flag.clone()) {
            return Err("Repeated worker option");
        }
        match flag.to_str() {
            Some("--model-root") if root.is_none() => {
                root = Some(PathBuf::from(
                    args.next().ok_or("Missing fixed model root")?,
                ))
            }
            Some("--parent-pid") if parent.is_none() => {
                parent = args
                    .next()
                    .and_then(|s| s.to_str().and_then(|s| s.parse::<i32>().ok()))
                    .filter(|pid| *pid > 1)
            }
            _ => return Err("Unknown or duplicate worker option"),
        }
    }
    let root = root
        .filter(|p| p.is_absolute())
        .ok_or("Missing absolute fixed model root")?;
    let parent = parent.ok_or("Missing exact worker parent")?;
    let instance = std::env::var("COMPUTA_GROUNDING_INSTANCE")
        .ok()
        .and_then(|s| Uuid::parse_str(&s).ok())
        .filter(|u| !u.is_nil())
        .ok_or("Missing exact worker instance")?;
    Ok(Options {
        root,
        parent,
        instance,
    })
}
fn parent_alive(parent: i32) -> bool {
    // SAFETY: getppid only reads this worker's OS parent, never a foreign handle.
    (unsafe { libc::getppid() }) == parent
}
fn read_frame(input: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; 4];
    if input.read(&mut header[..1])? == 0 {
        return Ok(None);
    }
    input.read_exact(&mut header[1..])?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > wire::MAX_REQUEST_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Grounding frame bound",
        ));
    }
    let mut bytes = vec![0; length];
    input.read_exact(&mut bytes)?;
    Ok(Some(bytes))
}
fn write_frame(output: &mut impl Write, value: &Response) -> io::Result<()> {
    let bytes = wire::encode(value, wire::MAX_RESPONSE_FRAME)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "Grounding response bound"))?;
    output.write_all(&(bytes.len() as u32).to_be_bytes())?;
    output.write_all(&bytes)?;
    output.flush()
}
fn code(error: &GroundingError) -> RefusalCode {
    match error {
        GroundingError::Unavailable => RefusalCode::MissingModels,
        GroundingError::Installation => RefusalCode::Installation,
        GroundingError::Image => RefusalCode::InvalidImage,
        GroundingError::Target => RefusalCode::InvalidTarget,
        GroundingError::Processor => RefusalCode::Processor,
        GroundingError::Cancelled => RefusalCode::Cancelled,
        GroundingError::Model => RefusalCode::Model,
        GroundingError::Refusal(_) => RefusalCode::NoAgreement,
        GroundingError::Platform => RefusalCode::Platform,
    }
}
fn model_name(name: &str) -> Result<ModelName, wire::WireError> {
    match name {
        "goclick" | "goclick-base-4bit" => Ok(ModelName::GoClick),
        "gui_owl_2b" | "gui-owl-2b" => Ok(ModelName::GuiOwl),
        "showui" | "showui-2b-4bit" => Ok(ModelName::ShowUi),
        _ => Err(wire::WireError),
    }
}
fn result(
    binding: &CaptureBinding,
    reply: GroundingReply,
) -> Result<wire::GroundingResult, wire::WireError> {
    if reply.protocol_version != wire::PROTOCOL_VERSION
        || reply.method_version != wire::METHOD_VERSION
        || reply.image_sha256 != binding.png_sha256.as_str()
        || reply.target_sha256 != binding.target_sha256.as_str()
        || reply.width != binding.width
        || reply.height != binding.height
    {
        return Err(wire::WireError);
    }
    let point = |p: computa_inference::grounding::Point| wire::PixelPoint { x: p.x, y: p.y };
    let model_points = reply
        .model_points
        .into_iter()
        .map(|(name, p)| Ok((model_name(name)?, p.map(point))))
        .collect::<Result<BTreeMap<_, _>, wire::WireError>>()?;
    let model_seconds = reply
        .model_seconds
        .into_iter()
        .map(|(name, s)| Ok((model_name(name)?, s)))
        .collect::<Result<BTreeMap<_, _>, wire::WireError>>()?;
    let result = wire::GroundingResult {
        point: point(reply.selection.point),
        used_showui: reply.selection.used_showui,
        selected_pair: [
            model_name(reply.selection.selected_pair[0])?,
            model_name(reply.selection.selected_pair[1])?,
        ],
        initial_distance_normalized_diagonal: reply.selection.initial_distance_normalized_diagonal,
        selected_distance_normalized_diagonal: reply
            .selection
            .selected_distance_normalized_diagonal,
        model_points,
        model_seconds,
        elapsed_seconds: reply.elapsed_seconds,
    };
    result.validate(binding)?;
    Ok(result)
}
fn pixels(binding: &CaptureBinding, encoded: &str, target: &str) -> Result<Vec<u8>, RefusalCode> {
    let bytes = STANDARD
        .decode(encoded)
        .map_err(|_| RefusalCode::InvalidImage)?;
    if bytes.is_empty()
        || bytes.len() > wire::MAX_PNG_BYTES
        || STANDARD.encode(&bytes) != encoded
        || hex::encode(Sha256::digest(&bytes)) != binding.png_sha256.as_str()
        || bytes.len() < 33
        || &bytes[..8] != b"\x89PNG\r\n\x1a\n"
        || &bytes[12..16] != b"IHDR"
        || u32::from_be_bytes(
            bytes[16..20]
                .try_into()
                .map_err(|_| RefusalCode::InvalidImage)?,
        ) != binding.width
        || u32::from_be_bytes(
            bytes[20..24]
                .try_into()
                .map_err(|_| RefusalCode::InvalidImage)?,
        ) != binding.height
    {
        return Err(RefusalCode::InvalidImage);
    }
    if hex::encode(Sha256::digest(target.as_bytes())) != binding.target_sha256.as_str() {
        return Err(RefusalCode::InvalidTarget);
    }
    Ok(bytes)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
fn run(options: Options) -> io::Result<()> {
    if !parent_alive(options.parent) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Worker parent mismatch",
        ));
    }
    let parent = options.parent;
    std::thread::Builder::new()
        .name("computa-grounding-parent".into())
        .spawn(move || {
            loop {
                std::thread::sleep(Duration::from_millis(250));
                if !parent_alive(parent) {
                    // SAFETY: orphaning can only terminate this worker, releasing its own
                    // Metal allocations; no destructors or foreign process signals run.
                    unsafe {
                        libc::_exit(0);
                    }
                }
            }
        })?;
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let startup = Instant::now();
    let loaded = computa_inference::metal_resources::verify_colocated()
        .map_err(|_| GroundingError::Installation)
        .and_then(|()| {
            VerifiedGroundingInstallation::verify(&options.root, || {
                parent_alive(parent) && startup.elapsed() < Duration::from_secs(30)
            })
        })
        .and_then(|installation| {
            computa_inference::grounding_backend::OwnedGrounder::load_verified(installation, || {
                parent_alive(parent) && startup.elapsed() < Duration::from_secs(30)
            })
        });
    let mut grounder = match loaded {
        Ok(model) => model,
        Err(error) => {
            write_frame(
                &mut output,
                &Response::Refused {
                    instance: options.instance,
                    binding: None,
                    code: code(&error),
                },
            )?;
            return Ok(());
        }
    };
    write_frame(
        &mut output,
        &Response::Ready {
            protocol_version: wire::PROTOCOL_VERSION,
            method_version: wire::METHOD_VERSION.into(),
            instance: options.instance,
            parent_pid: parent as u32,
            model_names: wire::MODELS,
        },
    )?;
    let mut seen = HashSet::new();
    while parent_alive(parent) {
        let Some(bytes) = read_frame(&mut input)? else {
            break;
        };
        let request: Request =
            match wire::decode(&bytes, wire::MAX_REQUEST_FRAME).and_then(|request: Request| {
                request.validate()?;
                Ok(request)
            }) {
                Ok(request) => request,
                Err(_) => {
                    write_frame(
                        &mut output,
                        &Response::Refused {
                            instance: options.instance,
                            binding: None,
                            code: RefusalCode::InvalidRequest,
                        },
                    )?;
                    break;
                }
            };
        match request {
            Request::Shutdown { instance } if instance == options.instance => {
                write_frame(&mut output, &Response::Stopped { instance })?;
                break;
            }
            Request::Warmup {
                binding,
                png_base64,
            } if binding.instance == options.instance
                && seen.is_empty()
                && seen.insert(binding.request_id) =>
            {
                let response = match pixels(&binding, &png_base64, wire::WARMUP_TARGET) {
                    Err(code) => Response::Refused {
                        instance: options.instance,
                        binding: Some(binding),
                        code,
                    },
                    Ok(png) => {
                        let started = Instant::now();
                        match grounder.warm_png(&png, || {
                            parent_alive(parent) && started.elapsed() < Duration::from_secs(60)
                        }) {
                            Ok(()) => Response::Warmed {
                                binding,
                                elapsed_seconds: started.elapsed().as_secs_f64(),
                            },
                            Err(error) => Response::Refused {
                                instance: options.instance,
                                binding: Some(binding),
                                code: code(&error),
                            },
                        }
                    }
                };
                write_frame(&mut output, &response)?;
            }
            Request::Ground {
                binding,
                png_base64,
                target,
            } if binding.instance == options.instance
                && seen.len() < 4096
                && seen.insert(binding.request_id) =>
            {
                let response = match pixels(&binding, &png_base64, &target) {
                    Err(code) => Response::Refused {
                        instance: options.instance,
                        binding: Some(binding),
                        code,
                    },
                    Ok(png) => {
                        let started = Instant::now();
                        match grounder.ground_png(&png, &target, || {
                            parent_alive(parent) && started.elapsed() < Duration::from_secs(60)
                        }) {
                            Err(GroundingError::Refusal(computa_inference::grounding::GroundingRefusal::InsufficientValidPoints | computa_inference::grounding::GroundingRefusal::NoPairAgreement))=>Response::Unagreed{binding,elapsed_seconds:started.elapsed().as_secs_f64()},
                            Err(error) => Response::Refused {
                                instance: options.instance,
                                binding: Some(binding),
                                code: code(&error),
                            },
                            Ok(reply) => match result(&binding, reply) {
                                Ok(result) => Response::Grounded { binding, result },
                                Err(_) => Response::Refused {
                                    instance: options.instance,
                                    binding: Some(binding),
                                    code: RefusalCode::Model,
                                },
                            },
                        }
                    }
                };
                write_frame(&mut output, &response)?;
            }
            _ => {
                write_frame(
                    &mut output,
                    &Response::Refused {
                        instance: options.instance,
                        binding: None,
                        code: RefusalCode::InvalidRequest,
                    },
                )?;
                break;
            }
        }
    }
    Ok(())
}
fn main() {
    #[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
    let outcome = options()
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))
        .and_then(run);
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx")))]
    let outcome: io::Result<()> = Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "Native visual inference requires Apple Silicon macOS and native-mlx",
    ));
    if let Err(error) = outcome {
        eprintln!("Computa visual worker: {error}");
        std::process::exit(1);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stdio_frames_reject_excessive_lengths_partial_frames_and_trailing_authority() {
        assert!(
            read_frame(&mut &((wire::MAX_REQUEST_FRAME + 1) as u32).to_be_bytes()[..]).is_err()
        );
        assert!(read_frame(&mut &[0u8, 0, 0, 2, b'{'][..]).is_err());
        assert!(read_frame(&mut &[][..]).unwrap().is_none());
        let response = Response::Stopped {
            instance: Uuid::new_v4(),
        };
        let mut framed = vec![];
        write_frame(&mut framed, &response).unwrap();
        let length = u32::from_be_bytes(framed[..4].try_into().unwrap()) as usize;
        assert_eq!(length, framed.len() - 4);
        assert!(matches!(
            wire::decode::<Response>(&framed[4..], wire::MAX_RESPONSE_FRAME).unwrap(),
            Response::Stopped { .. }
        ));
    }
    #[test]
    fn pixels_do_not_accept_base64_aliases_or_unrelated_capture_bytes() {
        let png = b"not a PNG";
        let binding = CaptureBinding {
            instance: Uuid::new_v4(),
            request_id: Uuid::new_v4(),
            generation: Uuid::new_v4(),
            capture_id: Uuid::new_v4(),
            png_sha256: wire::Sha256::new(hex::encode(Sha256::digest(png))).unwrap(),
            target_sha256: wire::Sha256::new(hex::encode(Sha256::digest(b"Click button"))).unwrap(),
            width: 1,
            height: 1,
        };
        assert_eq!(
            pixels(&binding, &STANDARD.encode(png), "Click button").unwrap_err(),
            RefusalCode::InvalidImage
        );
    }
}
