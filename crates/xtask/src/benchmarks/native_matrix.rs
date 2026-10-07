//! Trusted subprocess adapter for the actual native Production Runtime gates.
//! The Send runner never holds AppKit/AX objects; the child owns its main thread.
use super::*;
use computa_runtime::process::{ObservedExit, OwnedProcess, isolated_environment};
use serde::Deserialize;
use serde_json::json;
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::Mutex;
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NativeMatrixConfig {
    pub executable: PathBuf,
    pub resources: PathBuf,
    pub worker: PathBuf,
    pub model_roots: HashMap<String, PathBuf>,
    pub port: u16,
    pub fixture_executable: Option<PathBuf>,
    pub grounding_resources: PathBuf,
    pub grounding_model_root: PathBuf,
}
pub struct NativeMatrixQualifier {
    config: NativeMatrixConfig,
    owned: Mutex<HashMap<uuid::Uuid, Arc<OwnedProcess>>>,
}
impl NativeMatrixQualifier {
    pub fn new(config: NativeMatrixConfig) -> Result<Arc<Self>> {
        ensure(
            config.port >= 1024 && !matches!(config.port, 1234 | 1237),
            "private_matrix_port_required",
        )?;
        for p in [&config.executable, &config.worker] {
            executable(p)?;
        }
        if let Some(p) = &config.fixture_executable {
            executable(p)?;
        }
        for p in [
            &config.resources,
            &config.grounding_resources,
            &config.grounding_model_root,
        ] {
            directory(p)?;
        }
        ensure(
            config
                .model_roots
                .keys()
                .all(|s| matches!(s.as_str(), "4b" | "9b" | "27b"))
                && !config.model_roots.is_empty(),
            "closed_model_roots_required",
        )?;
        for p in config.model_roots.values() {
            directory(p)?;
        }
        Ok(Arc::new(Self {
            config,
            owned: Mutex::new(HashMap::new()),
        }))
    }
}
fn directory(path: &Path) -> Result<()> {
    ensure(
        path.is_absolute()
            && std::fs::symlink_metadata(path)
                .is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink()),
        "exact_regular_directory_required",
    )
}
fn executable(path: &Path) -> Result<()> {
    ensure(path.is_absolute(), "absolute_executable_required")?;
    let m = std::fs::symlink_metadata(path)
        .map_err(|_| BenchmarkError("native_qualifier_unavailable"))?;
    ensure(
        m.is_file()
            && !m.file_type().is_symlink()
            && m.permissions().mode() & 0o111 != 0
            && m.len() <= 512 * 1024 * 1024,
        "exact_regular_executable_required",
    )
}
fn source(task: MatrixTask) -> String {
    hash(format!(
        "native-matrix-v1:{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        task.name(),
        include_str!("../../../computa-desktop/src/bin/computa-native-model-qualification.rs"),
        include_str!("../../../computa-desktop/src/bin/native_model/mod.rs"),
        include_str!("../../../computa-desktop/src/bin/native_model/audit.rs"),
        include_str!("../../../computa-desktop/src/bin/native_model/backend.rs"),
        include_str!("../../../computa-macos/src/bin/computa-native-qualification-fixture.rs"),
        include_str!("../../../computa-macos/src/qualification_fixture.rs"),
        include_str!("../../../computa-browser/src/qualification.rs")
    ))
}
impl MatrixQualifier for NativeMatrixQualifier {
    fn source_sha256(&self, task: MatrixTask, model: &str) -> Option<String> {
        if !matches!(model, "4b" | "9b") {
            return None;
        }
        self.config.model_roots.get(model)?;
        if matches!(
            task,
            MatrixTask::Semantic | MatrixTask::Combined | MatrixTask::Visual
        ) && self.config.fixture_executable.is_none()
        {
            return None;
        }
        Some(source(task))
    }
    fn qualify<'a>(&'a self, trial: &'a MatrixTrial) -> MatrixFuture<'a, MatrixOutcome> {
        Box::pin(async move {
            let model_root = self
                .config
                .model_roots
                .get(&trial.model)
                .ok_or(BenchmarkError("reviewed_model_root_missing"))?;
            if self.owned.lock().await.contains_key(&trial.id) {
                return Err(BenchmarkError("duplicate_native_trial"));
            }
            let config = json!({"trial_id":trial.id,"task":trial.task.name(),"model_id":trial.model_id,"resources":self.config.resources,"worker":self.config.worker,"model_root":model_root,"port":self.config.port,"fixture_executable":self.config.fixture_executable,"grounding_resources":self.config.grounding_resources,"grounding_model_root":self.config.grounding_model_root,"directory":trial.directory,"parent_pid":std::process::id()});
            save(&trial.directory, "native-config.json", &config)?;
            let home = trial.directory.join("SupervisorHome");
            let mut builder = std::fs::DirBuilder::new();
            use std::os::unix::fs::DirBuilderExt;
            builder
                .mode(0o700)
                .create(&home)
                .map_err(|_| BenchmarkError("supervisor_home_failed"))?;
            let environment = isolated_environment(&home, &trial.directory.join("CodexHome"));
            let (process, input, output) = OwnedProcess::spawn(
                &self.config.executable,
                &[trial
                    .directory
                    .join("native-config.json")
                    .to_string_lossy()
                    .into_owned()],
                &trial.directory,
                &environment,
            )
            .map_err(|_| BenchmarkError("native_trial_launch_failed"))?;
            drop(input);
            tokio::spawn(async move {
                let mut output = output;
                let _ = tokio::io::copy(&mut output, &mut tokio::io::sink()).await;
            });
            let process = Arc::new(process);
            self.owned.lock().await.insert(trial.id, process.clone());
            let deadline = tokio::time::Instant::now() + Duration::from_secs(925);
            loop {
                if process
                    .observed_exit()
                    .map_err(|_| BenchmarkError("native_trial_exit_unverified"))?
                    .is_some()
                {
                    break;
                }
                if tokio::time::Instant::now() >= deadline {
                    return Ok(MatrixOutcome::Failed("native_trial_deadline"));
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            let result = match read_json(&trial.directory.join("native-result.json")) {
                Ok(v) => v,
                Err(_) => return Ok(MatrixOutcome::Failed("native_trial_result_missing")),
            };
            ensure(
                result["protocol"] == "computa-rust-native-model-qualification-v1"
                    && result["trial_id"] == trial.id.to_string()
                    && result["task"] == trial.task.name()
                    && result["model_id"] == trial.model_id
                    && result["gate_source_sha256"] == source(trial.task),
                "native_trial_result_identity",
            )?;
            if result["passed"] != true
                || result["cleanup_confirmed"] != true
                || process
                    .observed_exit()
                    .map_err(|_| BenchmarkError("native_trial_exit_unverified"))?
                    != Some(ObservedExit::Exited(0))
            {
                return Ok(MatrixOutcome::Failed("native_model_gate_failed"));
            }
            let digest = |field: &str| {
                result[field]
                    .as_str()
                    .filter(|s| {
                        s.len() == 64
                            && s.bytes()
                                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                    })
                    .map(str::to_owned)
                    .ok_or(BenchmarkError("native_audit_digest_missing"))
            };
            let evidence = MatrixEvidence {
                trial_id: trial.id,
                task: trial.task,
                model_id: trial.model_id.clone(),
                wire_sha256: digest("wire_sha256")?,
                rollout_sha256: digest("rollout_sha256")?,
                independent_oracle_sha256: digest("independent_oracle_sha256")?,
                oracle_passed: result["oracle_passed"] == true,
            };
            let relative = Path::new(
                result["rollout_relative_path"]
                    .as_str()
                    .ok_or(BenchmarkError("rollout_path_missing"))?,
            );
            ensure(
                !relative.is_absolute()
                    && relative
                        .components()
                        .all(|c| matches!(c, std::path::Component::Normal(_)))
                    && relative
                        .components()
                        .next()
                        .is_some_and(|c| c.as_os_str() == "sessions"),
                "owned_rollout_path_required",
            )?;
            let home = trial.directory.join("CodexHome");
            let path = home.join(relative);
            let mut cursor = home.clone();
            for c in relative.components() {
                cursor.push(c);
                let m = std::fs::symlink_metadata(&cursor)
                    .map_err(|_| BenchmarkError("owned_rollout_missing"))?;
                ensure(
                    !m.file_type().is_symlink(),
                    "owned_rollout_symlink_rejected",
                )?;
            }
            let rollout = read_bounded(&path, 32 * 1024 * 1024)?;
            ensure(
                hash(read(&trial.directory.join("wire-metadata.jsonl"))?) == evidence.wire_sha256
                    && hash(read(&trial.directory.join("independent-oracle.json"))?)
                        == evidence.independent_oracle_sha256
                    && hash(rollout) == evidence.rollout_sha256,
                "native_audit_changed",
            )?;
            Ok(MatrixOutcome::Verified(evidence))
        })
    }
    fn cleanup<'a>(&'a self, trial: &'a MatrixTrial) -> MatrixFuture<'a, ()> {
        Box::pin(async move {
            let process = self.owned.lock().await.get(&trial.id).cloned();
            let Some(process) = process else {
                return Err(BenchmarkError("native_trial_ownership_missing"));
            };
            process
                .stop()
                .await
                .map_err(|_| BenchmarkError("native_trial_group_cleanup_unconfirmed"))?;
            let result = read_json(&trial.directory.join("native-result.json"))?;
            ensure(
                result["protocol"] == "computa-rust-native-model-qualification-v1"
                    && result["trial_id"] == trial.id.to_string()
                    && result["task"] == trial.task.name()
                    && result["model_id"] == trial.model_id
                    && result["cleanup_confirmed"] == true,
                "native_descendant_cleanup_unconfirmed",
            )?;
            ensure(
                tokio::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, self.config.port))
                    .await
                    .is_err(),
                "owned_matrix_listener_remained",
            )?;
            self.owned.lock().await.remove(&trial.id);
            Ok(())
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_digests_are_exact_and_gate_specific() {
        let status = source(MatrixTask::Status);
        assert_eq!(status.len(), 64);
        assert_ne!(status, source(MatrixTask::Interrupt));
        assert_eq!(status, source(MatrixTask::Status));
    }
    #[test]
    fn rejects_shared_listener_and_unknown_model_sources() {
        let c = NativeMatrixConfig {
            executable: "/bin/false".into(),
            resources: "/tmp".into(),
            worker: "/bin/false".into(),
            model_roots: HashMap::new(),
            port: 1237,
            fixture_executable: None,
            grounding_resources: "/tmp".into(),
            grounding_model_root: "/tmp".into(),
        };
        assert!(NativeMatrixQualifier::new(c).is_err());
    }
}
