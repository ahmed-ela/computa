//! Explicit actual bundled-worker qualification with absent models. This proves
//! the moved worker's Metal closure and finite missing-capability response, not
//! visual model accuracy. It never downloads or substitutes weights.
#![cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
use computa_contracts::grounding::{self as wire, RefusalCode, Response};
use std::{path::PathBuf, time::Duration};
use tokio::io::AsyncReadExt;
use uuid::Uuid;

#[tokio::test]
#[ignore = "explicit private bundled-worker qualification; requires reviewed resources path"]
async fn moved_native_worker_refuses_absent_models_and_exits_without_coordinates() {
    let resources = PathBuf::from(
        std::env::var_os("COMPUTA_TEST_GROUNDING_RESOURCES")
            .expect("absolute reviewed InferenceRuntime resources"),
    );
    assert!(resources.is_absolute());
    assert_eq!(resources.canonicalize().unwrap(), resources);
    computa_inference::metal_resources::verify_directory(&resources)
        .expect("exact colocated compiled Metal pin");
    let executable = resources.join("computa-grounding-worker");
    let metadata = std::fs::symlink_metadata(&executable).unwrap();
    assert!(metadata.is_file() && !metadata.file_type().is_symlink());
    let home = tempfile::tempdir().unwrap();
    let instance = Uuid::new_v4();
    let mut child = tokio::process::Command::new(executable)
        .args([
            "--model-root",
            home.path().join("absent-models").to_str().unwrap(),
            "--parent-pid",
            &std::process::id().to_string(),
        ])
        .env_clear()
        .env("HOME", home.path())
        .env("TMPDIR", home.path())
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("COMPUTA_GROUNDING_INSTANCE", instance.to_string())
        .current_dir(home.path())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let pid = child.id().unwrap();
    let mut output = child.stdout.take().unwrap();
    let response = tokio::time::timeout(Duration::from_secs(30), async {
        let mut header = [0; 4];
        output.read_exact(&mut header).await.unwrap();
        let length = u32::from_be_bytes(header) as usize;
        assert!((1..=wire::MAX_RESPONSE_FRAME).contains(&length));
        let mut bytes = vec![0; length];
        output.read_exact(&mut bytes).await.unwrap();
        wire::decode::<Response>(&bytes, wire::MAX_RESPONSE_FRAME).unwrap()
    })
    .await
    .expect("bounded actual native worker startup");
    assert!(
        matches!(response,Response::Refused{instance:returned,binding:None,code:RefusalCode::MissingModels} if returned==instance)
    );
    let exit = tokio::time::timeout(Duration::from_secs(3), child.wait())
        .await
        .expect("exact child exits")
        .unwrap();
    assert!(
        exit.success(),
        "finite capability refusal is a clean terminal state"
    );
    let mut trailing = Vec::new();
    output.read_to_end(&mut trailing).await.unwrap();
    assert!(
        trailing.is_empty(),
        "no invented ready record, coordinates, or extra frames"
    );
    println!(
        "OWNED_GROUNDING_STARTUP_QUALIFIED exact_pid={pid} exact_metal=true missing_models=true no_coordinates=true child_reaped=true"
    );
}
