//! Explicit crash fixture retains authority before the worker becomes orphaned.
#![cfg(target_os = "macos")]
use computa_runtime::process::{ObservedExit, OwnedProcess};
use std::{collections::BTreeMap, path::Path, time::Duration};
use tokio::io::{AsyncBufReadExt, BufReader};

#[tokio::test]
#[ignore = "Only the owned parent-death fixture launches this supervisor"]
async fn supervisor_fixture() {
    assert_eq!(
        std::env::var("COMPUTA_PROBE_SUPERVISOR").as_deref(),
        Ok("1")
    );
    let (worker, input, output) = OwnedProcess::spawn(
        Path::new("/bin/sleep"),
        &["30".into()],
        &std::env::current_dir().unwrap(),
        &BTreeMap::new(),
    )
    .unwrap();
    drop(input);
    drop(output);
    println!("{{\"workerPid\":{}}}", worker.pid());
    // A failed parent assertion cannot leave this test fixture unbounded.
    tokio::time::sleep(Duration::from_secs(20)).await;
    worker.stop().await.unwrap();
}

#[tokio::test]
async fn retained_direct_descendant_can_be_cleaned_after_exact_supervisor_crash() {
    let private = tempfile::tempdir().unwrap();
    let exe = std::env::current_exe().unwrap();
    let (supervisor, input, output) = OwnedProcess::spawn(
        &exe,
        &[
            "--exact".into(),
            "supervisor_fixture".into(),
            "--ignored".into(),
            "--nocapture".into(),
        ],
        private.path(),
        &BTreeMap::from([("COMPUTA_PROBE_SUPERVISOR".into(), "1".into())]),
    )
    .unwrap();
    drop(input);
    let mut lines = BufReader::new(output).lines();
    let reported = tokio::time::timeout(Duration::from_secs(5), async {
        for _ in 0..16 {
            let line = lines.next_line().await.unwrap().unwrap();
            if line.len() > 128 {
                return None;
            }
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(&line)
                && let Some(pid) = value["workerPid"]
                    .as_i64()
                    .and_then(|n| i32::try_from(n).ok())
            {
                return Some(pid);
            }
        }
        None
    })
    .await
    .unwrap()
    .unwrap();
    assert!(
        supervisor
            .capture_descendant_for_lifecycle_probe(
                reported,
                Path::new("/bin/sleep"),
                &["999".into()]
            )
            .await
            .is_err()
    );
    assert!(
        supervisor
            .capture_descendant_for_lifecycle_probe(
                std::process::id() as i32,
                Path::new("/bin/sleep"),
                &["30".into()]
            )
            .await
            .is_err()
    );
    let worker = supervisor
        .capture_descendant_for_lifecycle_probe(reported, Path::new("/bin/sleep"), &["30".into()])
        .await
        .unwrap();
    assert_eq!(worker.pid(), reported);
    assert!(worker.matches_current().unwrap());
    assert_eq!(
        supervisor.crash_for_lifecycle_probe().await.unwrap(),
        ObservedExit::Signalled(libc::SIGKILL)
    );
    tokio::time::sleep(Duration::from_millis(25)).await;
    assert!(
        worker.matches_current().unwrap(),
        "Fixture worker deliberately has no parent watcher"
    );
    worker.stop_for_lifecycle_probe().await.unwrap();
    worker.stop_for_lifecycle_probe().await.unwrap();
    assert!(!worker.matches_current().unwrap());
    supervisor.stop().await.unwrap();
    assert!(
        supervisor
            .capture_descendant_for_lifecycle_probe(
                reported,
                Path::new("/bin/sleep"),
                &["30".into()]
            )
            .await
            .is_err()
    );
}
