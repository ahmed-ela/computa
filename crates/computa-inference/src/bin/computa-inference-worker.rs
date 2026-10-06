use computa_contracts::models::{LocalModel, ModelId};
use computa_inference::{request, server::Worker};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
};
use uuid::Uuid;
struct Options {
    root: PathBuf,
    fallback: Option<PathBuf>,
    model: Option<LocalModel>,
    port: u16,
    parent: i32,
    instance: Uuid,
}
fn options() -> Result<Options, String> {
    let mut values = HashMap::new();
    let mut seen = HashSet::new();
    let mut args = std::env::args_os().skip(1);
    while let Some(flag) = args.next() {
        let flag = flag.to_str().ok_or("Invalid worker option")?.to_owned();
        if ![
            "--model-root",
            "--fallback-model-root",
            "--model-id",
            "--port",
            "--parent-pid",
        ]
        .contains(&flag.as_str())
            || !seen.insert(flag.clone())
        {
            return Err("Unknown or repeated worker option".into());
        }
        values.insert(flag, args.next().ok_or("Missing worker option value")?);
    }
    let root = PathBuf::from(values.remove("--model-root").ok_or("Missing model root")?);
    let fallback = values.remove("--fallback-model-root").map(PathBuf::from);
    let model = values
        .remove("--model-id")
        .map(
            |id| match id.to_str().and_then(|id| ModelId::parse(id).ok()) {
                Some(ModelId::Local(model)) if model.supports_headless_mlx() => Ok(model),
                _ => Err("Unsupported worker model".to_owned()),
            },
        )
        .transpose()?;
    let port = values
        .remove("--port")
        .and_then(|v| v.to_str().and_then(|v| v.parse::<u16>().ok()))
        .filter(|&p| p >= 1024)
        .ok_or("Invalid worker port")?;
    let parent = values
        .remove("--parent-pid")
        .and_then(|v| v.to_str().and_then(|v| v.parse::<i32>().ok()))
        .filter(|&pid| pid > 1)
        .ok_or("Invalid worker parent")?;
    let instance = std::env::var("HEYDASH_MLX_INSTANCE")
        .ok()
        .and_then(|s| Uuid::parse_str(&s).ok())
        .ok_or("Missing exact worker instance")?;
    Ok(Options {
        root,
        fallback,
        model,
        port,
        parent,
        instance,
    })
}
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("Computa native inference: {error}");
        std::process::exit(1);
    }
}
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
async fn run() -> Result<(), String> {
    let options = options()?;
    // SAFETY: getppid has no arguments and returns the process's OS parent PID.
    if unsafe { libc::getppid() } != options.parent {
        return Err("Worker must be started by its exact app parent".into());
    }
    computa_inference::metal_resources::verify_colocated()
        .map_err(|_| "The native worker Metal resources are missing or differ from its build")?;
    let mut models = request::discover_models(&options.root, options.fallback.as_deref());
    if let Some(model) = options.model {
        if options.root.join("config.json").is_file() {
            models = HashMap::from([(
                model,
                options
                    .root
                    .canonicalize()
                    .map_err(|_| "Invalid model directory")?,
            )]);
        } else {
            models.retain(|id, _| *id == model);
        }
    }
    if models.is_empty() {
        return Err("No installed supported models; nothing was downloaded".into());
    }
    let backend_models = models.clone();
    let worker = Worker::spawn(models, options.instance, move || {
        Ok(Box::new(computa_inference::mlx::OwnedModel::new(
            backend_models,
        )?))
    })
    .await
    .map_err(|e| e.to_string())?;
    let parent = options.parent;
    std::thread::Builder::new()
        .name("computa-parent-watch".into())
        .spawn(move || {
            loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
                // SAFETY: only reads this process's parent. _exit terminates this owned
                // worker immediately after orphaning, releasing Metal allocations.
                if unsafe { libc::getppid() } != parent {
                    unsafe { libc::_exit(0) };
                }
            }
        })
        .map_err(|_| "Could not watch worker parent")?;
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, options.port))
        .await
        .map_err(|_| "The worker port is already occupied; no listener was adopted")?;
    let stopping = worker.clone();
    axum::serve(listener, worker.router())
        .with_graceful_shutdown(async move {
            let mut term =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    .expect("SIGTERM handler");
            tokio::select! {_=tokio::signal::ctrl_c()=>{},_=term.recv()=>{}}
            stopping.shutdown();
        })
        .await
        .map_err(|_| "Owned inference listener failed")?;
    Ok(())
}
#[cfg(not(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx")))]
fn main() {
    eprintln!("Computa native MLX inference requires arm64 macOS and native-mlx.");
    std::process::exit(1);
}
