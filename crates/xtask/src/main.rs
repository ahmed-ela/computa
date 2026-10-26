use clap::{Parser, Subcommand, ValueEnum};
use std::{io, path::PathBuf};
use xtask::distribution::{PackageOptions, ReleaseChannel, SystemRunner};
#[derive(Parser)]
#[command(name = "Computa build tools")]
struct Args {
    #[command(subcommand)]
    command: Task,
}
#[derive(Clone, Copy, ValueEnum)]
enum Channel {
    SignedTest,
    Notarized,
}
#[derive(clap::Args)]
struct EvidenceSourceArgs {
    #[arg(long)]
    template: PathBuf,
    #[arg(long)]
    policy: PathBuf,
    #[arg(long)]
    compact: PathBuf,
    #[arg(long)]
    prefix: PathBuf,
    #[arg(long)]
    output: PathBuf,
    #[arg(long)]
    endpoint: String,
    #[arg(long)]
    observation: String,
    #[arg(long, value_enum, required=true, num_args=1..=3)]
    arms: Vec<xtask::benchmarks::EvidenceArm>,
}
#[derive(Subcommand)]
enum Task {
    Check,
    BuildWeb {
        #[arg(long, default_value = "wasm-bindgen")]
        wasm_bindgen: String,
        #[arg(long)]
        release: bool,
    },
    PrepareRuntime {
        #[arg(long)]
        source_dir: Option<PathBuf>,
    },
    BuildRuntime {
        #[arg(long)]
        source_dir: Option<PathBuf>,
        #[arg(long)]
        release: bool,
    },
    Website,
    Models {
        #[arg(long, default_value = "4b", value_parser = ["4b", "9b"])]
        model: String,
        #[arg(long)]
        model_root: PathBuf,
        #[arg(long)]
        download_model: bool,
    },
    Setup {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        options: Vec<String>,
    },
    SignRelease {
        #[arg(long)]
        app: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        signing_identity: String,
    },
    PackageRelease {
        #[arg(long)]
        app: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        installer: PathBuf,
        #[arg(long)]
        tag: String,
        #[arg(long, value_enum)]
        channel: Channel,
    },
    InstallRelease {
        #[arg(long)]
        package_root: PathBuf,
        #[arg(long)]
        download_model: bool,
        #[arg(long)]
        no_launch: bool,
    },
    RestoreBackup {
        #[arg(long)]
        backup: PathBuf,
    },
    AxRun {
        #[arg(long)]
        fixtures: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        lms: PathBuf,
    },
    ReplayLayout {
        #[arg(long)]
        captures: PathBuf,
        #[arg(long)]
        fixture_a: PathBuf,
        #[arg(long)]
        fixture_b: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        policy: PathBuf,
        #[arg(long)]
        lms: PathBuf,
    },
    AuditWire {
        #[arg(long)]
        captures: PathBuf,
        #[arg(long, required = true, num_args = 1..=8)]
        fixtures: Vec<PathBuf>,
        #[arg(long)]
        policy: PathBuf,
    },
    ParentBlocks {
        #[arg(long)]
        snapshot: PathBuf,
        #[arg(long, default_value_t = 24000, value_parser = clap::value_parser!(u32).range(1..=200000))]
        character_budget: u32,
    },
    SummarizeMatrix {
        #[arg(long)]
        trials: PathBuf,
    },
    MakeAxFixtures,
    ServeLookupFixtures {
        #[arg(long)]
        directory: PathBuf,
        #[arg(long, default_value_t = 4321, value_parser = clap::value_parser!(u16).range(1024..))]
        port: u16,
    },
    GroundingSources {
        #[arg(long)]
        model_root: PathBuf,
        #[arg(long)]
        download_model: bool,
    },
    /// Install the three reviewed native grounding artifacts; network is opt-in.
    GroundingInstall {
        #[arg(long)]
        root: PathBuf,
        #[arg(long)]
        source_root: PathBuf,
        #[arg(long)]
        download_model: bool,
    },
    /// Import exactly pinned local artifacts from a closed three-key JSON map.
    GroundingImport {
        #[arg(long)]
        root: PathBuf,
        #[arg(long)]
        artifacts_json: PathBuf,
    },
    /// Verify an existing native or legacy grounding installation without changes.
    GroundingVerify {
        #[arg(long)]
        root: PathBuf,
    },
    /// Qualification-only single model conversion; does not publish an installation.
    GroundingConvert {
        #[arg(long, value_parser = ["goclick-base-4bit", "gui-owl-2b"])]
        model: String,
        #[arg(long)]
        source: PathBuf,
        #[arg(long)]
        output: PathBuf,
    },
    ContextCapture {
        #[arg(long)]
        output: PathBuf,
        #[arg(long, default_value_t = 32160, value_parser = clap::value_parser!(u16).range(1024..))]
        port: u16,
    },
    ContextReplay {
        #[arg(long)]
        request: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long, default_value_t = 1, value_parser = clap::value_parser!(u8).range(1..=10))]
        count: u8,
        #[arg(long)]
        temperature: Option<f64>,
        #[arg(long)]
        assistant: Option<PathBuf>,
    },
    PairedContext {
        #[arg(long)]
        request: PathBuf,
        #[arg(long)]
        rollout: PathBuf,
        #[arg(long)]
        plan: PathBuf,
        #[arg(long)]
        output: PathBuf,
    },
    AuditClickability {
        #[arg(long)]
        rollout: PathBuf,
        #[arg(long)]
        turn: String,
        #[arg(long)]
        marker: Option<String>,
    },
    AuditLookup {
        #[arg(long)]
        rollout: PathBuf,
        #[arg(long)]
        turn: String,
    },
    ServingProbe {
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        endpoint: String,
        #[arg(long)]
        rollout: PathBuf,
        #[arg(long)]
        synthetic_png: PathBuf,
        #[arg(long)]
        policy: PathBuf,
        #[arg(long, default_value = "all")]
        only: String,
        #[arg(long)]
        observation: String,
        #[arg(long, default_value = "lmstudio-community/Qwen3.5-4B-MLX-4bit", value_parser = ["lmstudio-community/Qwen3.5-4B-MLX-4bit", "lmstudio-community/Qwen3.5-9B-MLX-4bit"])]
        model: String,
    },
    BenchmarkNativeOcr {
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        cpu_only: bool,
    },
    BenchmarkRenderFixtures {
        #[arg(long)]
        fixtures: PathBuf,
        #[arg(long)]
        output: PathBuf,
    },
    MakeOpaqueFixtures {
        #[arg(long)]
        output: PathBuf,
    },
    OpaqueRun {
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        actual: PathBuf,
        #[arg(long)]
        rollout: PathBuf,
        #[arg(long)]
        policy: PathBuf,
        #[arg(long)]
        lms: Option<PathBuf>,
        #[arg(long, default_value = "lmstudio-community/Qwen3.5-4B-MLX-4bit", value_parser = ["lmstudio-community/Qwen3.5-4B-MLX-4bit", "lmstudio-community/Qwen3.5-9B-MLX-4bit"])]
        model: String,
        #[arg(long, default_value_t = 4096, value_parser = clap::value_parser!(u64).range(1..=4096))]
        max_output_tokens: u64,
        #[arg(long)]
        case_id: Option<String>,
        #[arg(long)]
        endpoint: String,
        #[arg(long)]
        observation: String,
    },
    MakeEvidenceFixtures,
    /// Run exact native Runtime gates only with an explicit trusted config.
    MatrixRun {
        #[arg(long)]
        output: PathBuf,
        #[arg(long, default_value = "4b,9b")]
        models: String,
        #[arg(long, default_value = "status,semantic,combined,visual")]
        tasks: String,
        #[arg(long, default_value_t = 3, value_parser = clap::value_parser!(u8).range(1..=20))]
        repetitions: u8,
        #[arg(long)]
        dry_run: bool,
        /// Absolute path to closed JSON config; enables actual owned native subprocess gates.
        #[arg(long, conflicts_with = "dry_run")]
        native_config: Option<PathBuf>,
    },
    BoundaryProbe {
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        request: PathBuf,
        #[arg(long)]
        policy: PathBuf,
        #[arg(long)]
        endpoint: String,
        #[arg(long)]
        observation: String,
    },
    ScoreEvidence {
        #[arg(long)]
        answer: PathBuf,
        #[arg(long)]
        expected: PathBuf,
    },
    GroundingCascade {
        #[arg(long)]
        corpus: PathBuf,
        #[arg(long)]
        worker: PathBuf,
        #[arg(long)]
        model_root: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long, default_value_t = 90)]
        expected_hits: u16,
        #[arg(long, default_value_t = 1)]
        expected_refusals: u16,
    },
    ParentDeathProbe {
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        worker: PathBuf,
        #[arg(long)]
        model_root: PathBuf,
        #[arg(long)]
        policy: PathBuf,
        #[arg(long,value_parser=clap::value_parser!(u16).range(1024..))]
        port: u16,
        #[arg(long)]
        load_4b: bool,
    },
    #[command(hide = true)]
    BenchmarkParentDeathSupervisor {
        #[arg(long)]
        worker: PathBuf,
        #[arg(long)]
        model_root: PathBuf,
        #[arg(long,value_parser=clap::value_parser!(u16).range(1024..))]
        port: u16,
        #[arg(long)]
        instance: uuid::Uuid,
    },
    ReceiptFloorAudit {
        #[arg(long)]
        source: PathBuf,
        #[arg(long)]
        dependencies: PathBuf,
        #[arg(long)]
        compiler: PathBuf,
        #[arg(long)]
        rollout: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        turn: uuid::Uuid,
    },
    EvidenceRun {
        #[command(flatten)]
        source: EvidenceSourceArgs,
        #[arg(long)]
        images: PathBuf,
        #[arg(long,value_parser=["development","holdout"])]
        split: String,
        #[arg(long, value_enum, default_value = "pipeline")]
        mode: xtask::benchmarks::EvidenceMode,
    },
    EvidenceRegression {
        #[command(flatten)]
        source: EvidenceSourceArgs,
        #[arg(long)]
        rollout: PathBuf,
    },
    EvidenceRetention {
        #[arg(long)]
        baseline: PathBuf,
        #[arg(long)]
        exporter: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(long)]
        endpoint: Option<String>,
        #[arg(long)]
        observation: Option<String>,
        #[arg(long,requires_all=["endpoint","observation"])]
        replay: bool,
    },
    SummarizeEvidence {
        #[arg(long,required=true,num_args=1..=16)]
        summaries: Vec<PathBuf>,
    },
}
#[tokio::main]
async fn main() -> io::Result<()> {
    let command = Args::parse().command;
    // Release installers are copied outside the checkout. Only source commands
    // depend on this build-time checkout path; distribution commands do not.
    let source_root = || {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
    };
    let user_home = || computa_state::account::user_home().map_err(xtask::distribution::invalid);
    match command {
        Task::Check => {
            let root = source_root()?;
            xtask::runtime_source::run("cargo", &["fmt", "--all", "--check"], &root, false)?;
            xtask::runtime_source::run(
                "cargo",
                &[
                    "clippy",
                    "--workspace",
                    "--all-targets",
                    "--locked",
                    "--",
                    "-D",
                    "warnings",
                ],
                &root,
                false,
            )?;
            xtask::runtime_source::run(
                "cargo",
                &["test", "--workspace", "--locked"],
                &root,
                false,
            )?;
            xtask::runtime_source::run(
                "cargo",
                &[
                    "check",
                    "--locked",
                    "-p",
                    "computa-ui",
                    "-p",
                    "--target",
                    "wasm32-unknown-unknown",
                ],
                &root,
                false,
            )?;
        }
        Task::BuildWeb {
            wasm_bindgen,
            release,
        } => println!(
            "{}",
            xtask::assets::build_web(&source_root()?, &wasm_bindgen, release)?.display()
        ),
        Task::PrepareRuntime { source_dir } => {
            let root = source_root()?;
            let source = source_dir.unwrap_or(root.join(".build/runtime/codex-source-reviewed"));
            let pin = xtask::runtime_source::prepare(&root, &source)?;
            println!(
                "Verified runtime source {} at {}",
                source.display(),
                pin.source_commit
            );
        }
        Task::BuildRuntime {
            source_dir,
            release,
        } => {
            let root = source_root()?;
            let source = source_dir.unwrap_or(root.join(".build/runtime/codex-source-reviewed"));
            println!(
                "{}",
                xtask::runtime_source::build(&root, &source, release)?.display()
            );
        }
        Task::Website => println!("{}", xtask::assets::website(&source_root()?)?.display()),
        Task::Models {
            model,
            model_root,
            download_model,
        } => {
            let selected = xtask::models::ReviewedModel::parse(&model)?;
            let installed =
                xtask::models::install_reviewed_model(&model_root, selected, download_model)
                    .await?;
            println!("{}", installed.display());
        }
        Task::Setup { options } => {
            let options = xtask::setup::parse_options(&options)?;
            match xtask::setup::setup(&options, &source_root()?, &user_home()?, &SystemRunner)
                .await?
            {
                xtask::setup::SetupResult::Checked => println!("Setup checks passed"),
                xtask::setup::SetupResult::Built(app) => println!("{}", app.display()),
                xtask::setup::SetupResult::Installed(result) => {
                    println!("{}", result.app.display())
                }
            }
        }
        Task::SignRelease {
            app,
            output,
            signing_identity,
        } => println!(
            "{}",
            xtask::distribution::sign_release(&app, &output, &signing_identity, &SystemRunner)?
                .display()
        ),
        Task::PackageRelease {
            app,
            output,
            installer,
            tag,
            channel,
        } => {
            let channel = match channel {
                Channel::SignedTest => ReleaseChannel::SignedTest,
                Channel::Notarized => ReleaseChannel::Notarized,
            };
            let package = xtask::distribution::package_release(
                &PackageOptions {
                    app,
                    output,
                    installer,
                    tag,
                    channel,
                },
                &SystemRunner,
            )?;
            println!("{}", package.dmg.display());
        }
        Task::InstallRelease {
            package_root,
            download_model,
            no_launch,
        } => println!(
            "{}",
            xtask::distribution::install_release(
                &package_root,
                &user_home()?,
                download_model,
                !no_launch,
                &SystemRunner
            )
            .await?
            .app
            .display()
        ),
        Task::RestoreBackup { backup } => println!(
            "{}",
            xtask::distribution::restore_backup(&backup, &user_home()?, &SystemRunner)?
                .app
                .display()
        ),
        Task::AxRun {
            fixtures,
            output,
            lms,
        } => print_json(
            &xtask::benchmarks::ax_run(&fixtures, &output, &lms)
                .await
                .map_err(xtask::distribution::invalid)?,
        )?,
        Task::ReplayLayout {
            captures,
            fixture_a,
            fixture_b,
            output,
            policy,
            lms,
        } => print_json(
            &xtask::benchmarks::replay_layout(
                &captures, &fixture_a, &fixture_b, &output, &policy, &lms,
            )
            .await
            .map_err(xtask::distribution::invalid)?,
        )?,
        Task::AuditWire {
            captures,
            fixtures,
            policy,
        } => {
            let audit = xtask::benchmarks::audit_wire(&captures, &fixtures, &policy)
                .map_err(xtask::distribution::invalid)?;
            print_json(&audit)?;
            if !audit["audits"].as_array().is_some_and(|audits| {
                !audits.is_empty() && audits.iter().all(|item| item["contentVerified"] == true)
            }) {
                return Err(xtask::distribution::invalid(
                    "Captured request content could not be verified",
                ));
            }
        }
        Task::ParentBlocks {
            snapshot,
            character_budget,
        } => {
            let bytes = read_input(&snapshot)?;
            let snapshot = std::str::from_utf8(&bytes)
                .map_err(|_| xtask::distribution::invalid("Invalid UTF-8 snapshot"))?;
            println!(
                "{}",
                xtask::benchmarks::group_ax_snapshot_parents(snapshot, character_budget as usize)
            );
        }
        Task::SummarizeMatrix { trials } => {
            let bytes = read_input(&trials)?;
            let value = computa_contracts::strict_json::parse(&bytes)
                .map_err(xtask::distribution::invalid)?;
            let rows = value
                .as_array()
                .ok_or_else(|| xtask::distribution::invalid("Trials must be a JSON array"))?;
            print_json(
                &xtask::benchmarks::summarize_computer_matrix(rows)
                    .map_err(xtask::distribution::invalid)?,
            )?;
        }
        Task::MakeAxFixtures => print_json(
            &xtask::benchmarks::make_ax_fixtures().map_err(xtask::distribution::invalid)?,
        )?,
        Task::ServeLookupFixtures { directory, port } => {
            xtask::benchmarks::serve_lookup_fixtures(&directory, port)
                .await
                .map_err(xtask::distribution::invalid)?
        }
        Task::GroundingSources {
            model_root,
            download_model,
        } => print_json(&serde_json::to_value(
            xtask::grounding_setup::download_sources(&model_root, download_model).await?,
        )?)?,
        Task::GroundingInstall {
            root,
            source_root,
            download_model,
        } => {
            require_absolute(&root)?;
            require_absolute(&source_root)?;
            let models =
                xtask::grounding_setup::install_native(&root, &source_root, download_model).await?;
            print_json(&grounding_report(&root, &models, download_model))?;
        }
        Task::GroundingImport {
            root,
            artifacts_json,
        } => {
            require_absolute(&root)?;
            let value = computa_contracts::strict_json::parse(&read_input_limit(
                &artifacts_json,
                64 * 1024,
            )?)
            .map_err(xtask::distribution::invalid)?;
            let artifacts: std::collections::BTreeMap<String,PathBuf> = serde_json::from_value(value)
                .map_err(|_|xtask::distribution::invalid("Expected a closed map from the three reviewed model IDs to absolute artifact directories"))?;
            let expected = ["goclick-base-4bit", "gui-owl-2b", "showui-2b-4bit"];
            if artifacts.len() != expected.len()
                || expected.iter().any(|name| !artifacts.contains_key(*name))
                || artifacts.values().any(|path| !path.is_absolute())
            {
                return Err(xtask::distribution::invalid(
                    "Expected exactly the three reviewed model IDs and absolute artifact directories",
                ));
            }
            let models = xtask::grounding_setup::import_native(&root, &artifacts)?;
            print_json(&grounding_report(&root, &models, false))?;
        }
        Task::GroundingVerify { root } => {
            require_absolute(&root)?;
            xtask::grounding_setup::verify_installation(&root)?;
            print_json(&grounding_report(&root, &root.join("models"), false))?;
        }
        Task::GroundingConvert {
            model,
            source,
            output,
        } => print_json(&xtask::grounding_setup::convert_source(
            &model, &source, &output,
        )?)?,
        Task::ContextCapture { output, port } => xtask::benchmarks::context_capture(&output, port)
            .await
            .map_err(xtask::distribution::invalid)?,
        Task::ContextReplay {
            request,
            output,
            count,
            temperature,
            assistant,
        } => print_json(&serde_json::to_value(
            xtask::benchmarks::context_replay(
                &request,
                &output,
                usize::from(count),
                temperature,
                assistant.as_deref(),
            )
            .await
            .map_err(xtask::distribution::invalid)?,
        )?)?,
        Task::PairedContext {
            request,
            rollout,
            plan,
            output,
        } => print_json(
            &xtask::benchmarks::paired_context_files(&request, &rollout, &plan, &output)
                .map_err(xtask::distribution::invalid)?,
        )?,
        Task::AuditClickability {
            rollout,
            turn,
            marker,
        } => print_json(
            &xtask::benchmarks::audit_clickability(&rollout, &turn, marker.as_deref())
                .map_err(xtask::distribution::invalid)?,
        )?,
        Task::AuditLookup { rollout, turn } => print_json(
            &xtask::benchmarks::audit_lookup(&rollout, &turn)
                .map_err(xtask::distribution::invalid)?,
        )?,
        Task::ServingProbe {
            output,
            endpoint,
            rollout,
            synthetic_png,
            policy,
            only,
            observation,
            model,
        } => print_json(
            &xtask::benchmarks::serving_probe(&xtask::benchmarks::ServingProbeOptions {
                output,
                endpoint,
                rollout,
                synthetic_png,
                policy,
                only,
                observation,
                model,
            })
            .await
            .map_err(xtask::distribution::invalid)?,
        )?,
        Task::BenchmarkNativeOcr {
            input,
            output,
            cpu_only,
        } => print_json(
            &xtask::benchmarks::native_ocr(&input, &output, cpu_only)
                .map_err(xtask::distribution::invalid)?,
        )?,
        Task::BenchmarkRenderFixtures { fixtures, output } => print_json(
            &xtask::benchmarks::render_fixtures(&fixtures, &output)
                .map_err(xtask::distribution::invalid)?,
        )?,
        Task::MakeOpaqueFixtures { output } => print_json(
            &xtask::benchmarks::make_opaque_fixtures(&output)
                .map_err(xtask::distribution::invalid)?,
        )?,
        Task::OpaqueRun {
            output,
            manifest,
            actual,
            rollout,
            policy,
            lms,
            model,
            max_output_tokens,
            case_id,
            endpoint,
            observation,
        } => print_json(
            &xtask::benchmarks::opaque_run(&xtask::benchmarks::OpaqueRunOptions {
                output,
                manifest,
                actual,
                rollout,
                policy,
                lms,
                model,
                max_output_tokens,
                case_id,
                endpoint,
                observation,
            })
            .await
            .map_err(xtask::distribution::invalid)?,
        )?,
        Task::MakeEvidenceFixtures => print_json(
            &xtask::benchmarks::make_evidence_fixtures().map_err(xtask::distribution::invalid)?,
        )?,
        Task::MatrixRun {
            output,
            models,
            tasks,
            repetitions,
            dry_run,
            native_config,
        } => {
            let options = xtask::benchmarks::MatrixRunOptions {
                output,
                models,
                tasks,
                repetitions,
                dry_run,
            };
            let summary = if let Some(path) = native_config {
                let config = read_native_matrix_config(&path)?;
                let qualifier = xtask::benchmarks::NativeMatrixQualifier::new(config)
                    .map_err(xtask::distribution::invalid)?;
                xtask::benchmarks::run_computer_matrix_with_qualifier(&options, qualifier.as_ref())
                    .await
            } else {
                xtask::benchmarks::run_computer_matrix(&options).await
            }
            .map_err(xtask::distribution::invalid)?;
            print_json(&summary)?;
        }
        Task::BoundaryProbe {
            output,
            request,
            policy,
            endpoint,
            observation,
        } => print_json(
            &xtask::benchmarks::boundary_probe(&xtask::benchmarks::BoundaryProbeOptions {
                output,
                request,
                policy,
                endpoint,
                observation,
            })
            .await
            .map_err(xtask::distribution::invalid)?,
        )?,
        Task::ScoreEvidence { answer, expected } => {
            let expected = computa_contracts::strict_json::parse(&read_input(&expected)?)
                .map_err(xtask::distribution::invalid)?;
            let expected: xtask::benchmarks::EvidenceAnswer = serde_json::from_value(expected)
                .map_err(|_| {
                    xtask::distribution::invalid(
                        "Expected evidence must map exact names to strings or null",
                    )
                })?;
            if expected.len() > 32 {
                return Err(xtask::distribution::invalid(
                    "Expected evidence has more than 32 names",
                ));
            }
            let text = read_input(&answer)?;
            let text = std::str::from_utf8(&text)
                .map_err(|_| xtask::distribution::invalid("Answer must be UTF-8"))?;
            print_json(&serde_json::to_value(
                xtask::benchmarks::score_evidence_answer(text, &expected),
            )?)?;
        }
        Task::GroundingCascade {
            corpus,
            worker,
            model_root,
            output,
            expected_hits,
            expected_refusals,
        } => print_checked(
            &xtask::benchmarks::grounding_cascade(&xtask::benchmarks::GroundingCascadeOptions {
                corpus,
                worker,
                model_root,
                output,
                expected_hits: expected_hits.into(),
                expected_refusals: expected_refusals.into(),
            })
            .await
            .map_err(xtask::distribution::invalid)?,
            "passed",
        )?,
        Task::ParentDeathProbe {
            output,
            worker,
            model_root,
            policy,
            port,
            load_4b,
        } => print_json(
            &xtask::benchmarks::parent_death_probe(&xtask::benchmarks::ParentDeathOptions {
                output,
                worker,
                model_root,
                policy,
                port,
                load_4b,
            })
            .await
            .map_err(xtask::distribution::invalid)?,
        )?,
        Task::BenchmarkParentDeathSupervisor {
            worker,
            model_root,
            port,
            instance,
        } => xtask::benchmarks::parent_death_supervisor(&worker, &model_root, port, instance)
            .await
            .map_err(xtask::distribution::invalid)?,
        Task::ReceiptFloorAudit {
            source,
            dependencies,
            compiler,
            rollout,
            output,
            manifest,
            turn,
        } => print_json(
            &xtask::benchmarks::receipt_floor_audit(&xtask::benchmarks::ReceiptFloorOptions {
                source,
                dependencies,
                compiler,
                rollout,
                output,
                manifest,
                turn,
            })
            .await
            .map_err(xtask::distribution::invalid)?,
        )?,
        Task::EvidenceRun {
            source,
            images,
            split,
            mode,
        } => print_json(
            &xtask::benchmarks::evidence_run(&xtask::benchmarks::EvidenceRunOptions {
                template: source.template,
                policy: source.policy,
                compact: source.compact,
                prefix: source.prefix,
                images,
                output: source.output,
                endpoint: source.endpoint,
                observation: source.observation,
                split,
                arms: source.arms,
                mode,
            })
            .await
            .map_err(xtask::distribution::invalid)?,
        )?,
        Task::EvidenceRegression { source, rollout } => print_json(
            &xtask::benchmarks::evidence_regression(&xtask::benchmarks::EvidenceReplayOptions {
                template: source.template,
                policy: source.policy,
                compact: source.compact,
                prefix: source.prefix,
                rollout,
                output: source.output,
                endpoint: source.endpoint,
                observation: source.observation,
                arms: source.arms,
            })
            .await
            .map_err(xtask::distribution::invalid)?,
        )?,
        Task::EvidenceRetention {
            baseline,
            exporter,
            output,
            endpoint,
            observation,
            replay,
        } => print_json(
            &xtask::benchmarks::evidence_retention(&xtask::benchmarks::EvidenceRetentionOptions {
                baseline,
                exporter,
                output,
                endpoint,
                observation,
                verify_only: !replay,
            })
            .await
            .map_err(xtask::distribution::invalid)?,
        )?,
        Task::SummarizeEvidence { summaries } => {
            for path in summaries {
                let data = computa_contracts::strict_json::parse(&read_input(&path)?)
                    .map_err(xtask::distribution::invalid)?;
                print_json(
                    &xtask::benchmarks::summarize_evidence(&data)
                        .map_err(xtask::distribution::invalid)?,
                )?;
            }
        }
    }
    Ok(())
}
fn print_json(value: &serde_json::Value) -> io::Result<()> {
    println!(
        "{}",
        serde_json::to_string_pretty(value).map_err(xtask::distribution::invalid)?
    );
    Ok(())
}
fn require_absolute(path: &std::path::Path) -> io::Result<()> {
    if !path.is_absolute()
        || path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err(xtask::distribution::invalid(
            "Expected an absolute path without parent traversal",
        ));
    }
    Ok(())
}
fn grounding_report(
    root: &std::path::Path,
    models: &std::path::Path,
    download_requested: bool,
) -> serde_json::Value {
    use sha2::Digest;
    serde_json::json!({"verified":true,"root":root,"models":models,"downloadExplicitlyRequested":download_requested,
        "acceptedInstallationSchemas":[3,4],
        "compiledNativeManifestSHA256":hex::encode(sha2::Sha256::digest(xtask::grounding_setup::NATIVE_MANIFEST)),
        "compiledSourceManifestSHA256":hex::encode(sha2::Sha256::digest(xtask::grounding_setup::SOURCE_MANIFEST))})
}
fn print_checked(value: &serde_json::Value, key: &str) -> io::Result<()> {
    print_json(value)?;
    if value[key] == true {
        Ok(())
    } else {
        Err(xtask::distribution::invalid(
            "Qualification did not complete successfully; inspect its saved finite audit",
        ))
    }
}
fn read_input(path: &std::path::Path) -> io::Result<Vec<u8>> {
    read_input_limit(path, 32 * 1024 * 1024)
}
fn read_native_matrix_config(
    path: &std::path::Path,
) -> io::Result<xtask::benchmarks::NativeMatrixConfig> {
    let data = read_input_limit(path, 64 * 1024)?;
    let value =
        computa_contracts::strict_json::parse(&data).map_err(xtask::distribution::invalid)?;
    serde_json::from_value(value).map_err(|_| {
        xtask::distribution::invalid(
            "Native Matrix config must use the closed explicit-path schema",
        )
    })
}
fn read_input_limit(path: &std::path::Path, limit: u64) -> io::Result<Vec<u8>> {
    use std::{io::Read, os::unix::fs::OpenOptionsExt};
    if !path.is_absolute() {
        return Err(xtask::distribution::invalid("Input path must be absolute"));
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > limit {
        return Err(xtask::distribution::invalid(
            "Input file is invalid or too large",
        ));
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(xtask::distribution::invalid(
            "Input file grew beyond its limit",
        ));
    }
    Ok(bytes)
}
