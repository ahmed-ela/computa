use crate::{
    evidence::{FailureEvidenceStore, outcome_record},
    legacy_verification::LegacyBaseline,
    semantic::{ModelReference, ReadError, ReadPublication, ReferenceCapability, SemanticReader},
    verification::{SemanticMutation, VerificationError, VerificationPlan, VerifiedProperty},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use computa_contracts::{
    Identifier,
    appserver::{ContentItem, ExecutionScope, ToolOutput},
    tools::*,
};
use computa_macos::{
    AutomationError, AxSnapshot, BoundApplication, CapturedImage, InputAction, MacosBackend,
    NativeMutation, Point, TreeLimits, coordinates::ScreenshotCoordinateMapper, unix_time,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    future::Future,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

pub type LocalFuture<'a, T> = Pin<Box<dyn Future<Output = T> + 'a>>;
#[derive(Clone, Debug)]
pub struct NativeApproval {
    pub id: String,
    pub task_id: Identifier,
    pub title: String,
    pub summary: String,
    pub details: String,
}
/// Approval decisions originate in trusted native controls, never page messages.
pub trait ApprovalGate {
    fn approve<'a>(
        &'a mut self,
        request: NativeApproval,
    ) -> LocalFuture<'a, Result<bool, HarnessError>>;
}
#[derive(Clone, Debug)]
pub struct QualifiedGrounding {
    pub capture_id: Uuid,
    pub point: Point,
    pub model_points: Vec<(String, Point)>,
    pub method: GroundingMethod,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GroundingMethod {
    GoClickGuiOwlAgreement,
    ShowUiDisambiguated,
}
pub trait VisualGrounder {
    fn locate<'a>(
        &'a mut self,
        capture: &'a CapturedImage,
        target: &'a str,
        cancellation: &'a CancellationToken,
    ) -> LocalFuture<'a, Result<QualifiedGrounding, HarnessError>>;
}
pub struct UnavailableGrounder;
impl VisualGrounder for UnavailableGrounder {
    fn locate<'a>(
        &'a mut self,
        _capture: &'a CapturedImage,
        _target: &'a str,
        _cancel: &'a CancellationToken,
    ) -> LocalFuture<'a, Result<QualifiedGrounding, HarnessError>> {
        Box::pin(async {
            Err(HarnessError::Capability(
                "The qualified visual cascade is unavailable; no point or click was fabricated."
                    .into(),
            ))
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum HarnessError {
    #[error("The computer request belongs to a revoked or inactive turn.")]
    StaleScope,
    #[error("The requested action is outside the host's computer interaction policy.")]
    Policy,
    #[error("No application is bound in this turn. Bind an already-running app.")]
    Unbound,
    #[error(
        "The observed reference is stale, unexposed, or the wrong capability; no input was sent."
    )]
    StaleReference,
    #[error("The native user declined this action; no input was sent.")]
    Declined,
    #[error("The turn was cancelled; no further input was sent.")]
    Cancelled,
    #[error("Invalid computer argument: {0}")]
    Invalid(String),
    #[error("{0}")]
    Capability(String),
    #[error(transparent)]
    Native(#[from] AutomationError),
    #[error(transparent)]
    Read(#[from] ReadError),
    #[error(transparent)]
    Verification(#[from] VerificationError),
    #[error(transparent)]
    Validation(#[from] ToolValidationError),
    #[error("The action recovery budget is exhausted; outcome remains unverified.")]
    RecoveryExhausted,
    #[error(
        "A previous computer action awaits verification. Read the original target and verify its operation_id; no new input was dispatched."
    )]
    PendingOutcome,
}
#[derive(Clone)]
pub struct TurnAuthority(Arc<AtomicBool>);
impl TurnAuthority {
    pub fn new() -> Self {
        Self(Arc::new(AtomicBool::new(true)))
    }
    pub fn revoke(&self) {
        self.0.store(false, Ordering::Release)
    }
    pub fn check(&self) -> Result<(), HarnessError> {
        if self.0.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(HarnessError::StaleScope)
        }
    }
}
impl Default for TurnAuthority {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum DispatchState {
    NotDispatched,
    Dispatched,
    DeliveryUncertain,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ActionReceipt {
    pub operation_id: Uuid,
    pub call_id: String,
    pub dispatch: DispatchState,
    pub status: String,
    pub verified: Option<VerifiedProperty>,
    pub verification_reads: usize,
    pub plan: Option<VerificationPlan>,
    pub failure: Option<String>,
    #[serde(skip)]
    legacy_baseline: Option<LegacyBaseline>,
}

/// A Harness belongs to one active turn. Multiple native turns require distinct
/// backends so retained AX references and application bindings cannot cross tasks.
pub struct Harness<B: MacosBackend> {
    backend: B,
    policy: InteractionPolicy,
    scope: Option<ExecutionScope>,
    authority: TurnAuthority,
    binding: Option<BoundApplication>,
    browser_model: bool,
    reader: SemanticReader,
    publication: Option<ReadPublication>,
    capture: Option<CapturedImage>,
    capture_cursor: bool,
    capture_display: Option<u32>,
    operations: HashMap<Uuid, ActionReceipt>,
    calls: HashSet<String>,
    failures: HashMap<String, usize>,
    evidence: Option<FailureEvidenceStore>,
}
impl<B: MacosBackend> Harness<B> {
    pub fn new(backend: B, policy: InteractionPolicy) -> Self {
        Self {
            backend,
            policy,
            scope: None,
            authority: TurnAuthority::new(),
            binding: None,
            browser_model: false,
            reader: SemanticReader::default(),
            publication: None,
            capture: None,
            capture_cursor: false,
            capture_display: None,
            operations: HashMap::new(),
            calls: HashSet::new(),
            failures: HashMap::new(),
            evidence: None,
        }
    }
    pub fn set_failure_store(&mut self, store: FailureEvidenceStore) {
        self.evidence = Some(store)
    }
    pub fn set_browser_model(&mut self, value: bool) {
        self.browser_model = value
    }
    pub fn backend(&self) -> &B {
        &self.backend
    }
    pub fn authority(&self) -> TurnAuthority {
        self.authority.clone()
    }
    pub fn outcome_counts(&self) -> (u64, u64) {
        let unresolved = self
            .operations
            .values()
            .filter(|r| {
                matches!(
                    r.status.as_str(),
                    "verification_pending" | "dispatch_failed"
                )
            })
            .count() as u64;
        let failed = self
            .operations
            .values()
            .filter(|r| {
                matches!(
                    r.status.as_str(),
                    "verification_pending" | "dispatch_failed"
                ) && r.failure.is_some()
            })
            .count() as u64;
        (unresolved, failed)
    }
    pub fn begin_turn(&mut self, scope: ExecutionScope) -> Result<(), HarnessError> {
        if self.scope.is_some() {
            return Err(HarnessError::StaleScope);
        }
        if self.policy == InteractionPolicy::BackgroundOnly && scope.policy != self.policy {
            return Err(HarnessError::Policy);
        }
        self.backend.invalidate();
        self.reader.invalidate();
        self.binding = None;
        self.publication = None;
        self.capture = None;
        self.operations.clear();
        self.calls.clear();
        self.failures.clear();
        self.authority = TurnAuthority::new();
        self.scope = Some(scope);
        Ok(())
    }
    pub fn revoke(&mut self) {
        self.authority.revoke();
        self.backend.invalidate();
        self.binding = None;
        self.publication = None;
        self.capture = None;
        self.reader.invalidate();
    }
    pub async fn end_turn(&mut self) -> Vec<String> {
        self.authority.revoke();
        self.scope.take();
        let mut issues = vec![];
        if self
            .operations
            .values()
            .any(|r| r.status == "verification_pending")
        {
            issues.push("One or more dispatched computer actions remain unverified; this turn does not establish completion.".into())
        }
        self.backend.invalidate();
        self.binding = None;
        self.publication = None;
        self.capture = None;
        self.reader.invalidate();
        issues
    }
    fn check(
        &self,
        scope: &ExecutionScope,
        cancel: &CancellationToken,
    ) -> Result<(), HarnessError> {
        self.authority.check()?;
        if self.scope.as_ref() != Some(scope) {
            return Err(HarnessError::StaleScope);
        }
        if cancel.is_cancelled() {
            return Err(HarnessError::Cancelled);
        }
        Ok(())
    }
    fn binding(&self) -> Result<BoundApplication, HarnessError> {
        self.binding.clone().ok_or(HarnessError::Unbound)
    }
    fn current(
        &self,
        id: &str,
        index: usize,
    ) -> Result<(AxSnapshot, HashSet<usize>), HarnessError> {
        let publication = self
            .publication
            .as_ref()
            .ok_or(HarnessError::StaleReference)?;
        if uuid(id)? != publication.snapshot.id || !publication.exposed.contains(&index) {
            return Err(HarnessError::StaleReference);
        }
        Ok((publication.snapshot.clone(), publication.exposed.clone()))
    }
    fn reference(
        &self,
        token: &str,
        capability: Option<ReferenceCapability>,
    ) -> Result<ModelReference, HarnessError> {
        if token.len() > 256 {
            return Err(HarnessError::StaleReference);
        }
        let p = self
            .publication
            .as_ref()
            .ok_or(HarnessError::StaleReference)?;
        let reference = p
            .references
            .get(token)
            .ok_or(HarnessError::StaleReference)?;
        if reference.snapshot_id != p.snapshot.id
            || !p.exposed.contains(&reference.index)
            || capability.is_some_and(|c| c != reference.capability)
        {
            return Err(HarnessError::StaleReference);
        }
        Ok(reference.clone())
    }
    fn clear_observations(&mut self) {
        self.publication = None;
        self.capture = None;
        self.reader.invalidate();
    }
    fn emit_read(&mut self, publication: ReadPublication) -> ToolOutput {
        let text = publication.text.clone();
        self.publication = Some(publication);
        self.capture = None;
        ToolOutput::text(text, true)
    }
    fn canonicalize(&self, call: ToolCall) -> Result<ToolCall, HarnessError> {
        Ok(match call {
            ToolCall::ReadPage(args) => ToolCall::Snapshot(args),
            ToolCall::ReadRegion(args) => {
                let r = self.reference(&args.region_ref, Some(ReferenceCapability::Region))?;
                ToolCall::Snapshot(ReadArgs {
                    query: args.query,
                    view: args.view,
                    cursor: None,
                    snapshot_id: Some(r.snapshot_id.to_string()),
                    element_index: Some(r.index),
                })
            }
            ToolCall::Fill(args) => {
                let r = self.reference(&args.field_ref, Some(ReferenceCapability::Field))?;
                ToolCall::SetText(SetTextArgs {
                    snapshot_id: r.snapshot_id.to_string(),
                    element_index: r.index,
                    text: args.text,
                })
            }
            ToolCall::Press(args) => {
                let r = self.reference(&args.action_ref, None)?;
                let ReferenceCapability::Action(action) = r.capability else {
                    return Err(HarnessError::StaleReference);
                };
                let action: AxAction = serde_json::from_value(json!(action))
                    .map_err(|_| HarnessError::StaleReference)?;
                let postcondition = args
                    .postcondition
                    .map(|p| -> Result<_, HarnessError> {
                        let element = p
                            .region_ref
                            .map(|token| {
                                self.reference(&token, Some(ReferenceCapability::Region))
                                    .map(|r| r.index)
                            })
                            .transpose()?;
                        let detail = p
                            .detail_ref
                            .map(|token| {
                                self.reference(&token, Some(ReferenceCapability::Region))
                                    .map(|r| r.index)
                            })
                            .transpose()?;
                        Ok(Postcondition {
                            kind: p.kind,
                            element_index: element,
                            detail_element_index: detail,
                            expected: p.expected,
                        })
                    })
                    .transpose()?;
                ToolCall::Ax(ActionArgs {
                    snapshot_id: r.snapshot_id.to_string(),
                    element_index: r.index,
                    ax_action: action,
                    postcondition,
                })
            }
            other => other,
        })
    }
    // Main-thread tool dispatch carries each independent native authority
    // explicitly; no model argument can replace any of these borrowed services.
    #[allow(clippy::too_many_arguments)]
    pub async fn execute(
        &mut self,
        scope: &ExecutionScope,
        call_id: &Identifier,
        name: &str,
        args: Value,
        cancel: &CancellationToken,
        approval: &mut dyn ApprovalGate,
        grounder: &mut dyn VisualGrounder,
    ) -> ToolOutput {
        let result = self
            .execute_inner(scope, call_id, name, args, cancel, approval, grounder)
            .await;
        match result {
            Ok(output) => output,
            Err(error) => {
                let text = error.to_string();
                if matches!(error, HarnessError::RecoveryExhausted)
                    && let Some(store) = &self.evidence
                {
                    let (unresolved, failed) = self.outcome_counts();
                    if unresolved > 0 {
                        let record = outcome_record(
                            scope.thread_id.as_str().into(),
                            scope.turn_id.as_str().into(),
                            call_id.as_str().into(),
                            name.into(),
                            true,
                            unresolved,
                            failed,
                            unix_time(),
                        );
                        if let Err(error) = record.and_then(|record| store.append(record)) {
                            return ToolOutput::text(
                                format!(
                                    "{text}\nNative failure evidence could not be persisted: {error}"
                                ),
                                false,
                            );
                        }
                    }
                }
                ToolOutput::text(text, false)
            }
        }
    }
    #[allow(clippy::too_many_arguments)]
    async fn execute_inner(
        &mut self,
        scope: &ExecutionScope,
        call_id: &Identifier,
        name: &str,
        args: Value,
        cancel: &CancellationToken,
        approval: &mut dyn ApprovalGate,
        grounder: &mut dyn VisualGrounder,
    ) -> Result<ToolOutput, HarnessError> {
        self.check(scope, cancel)?;
        if self.calls.contains(call_id.as_str()) {
            return Err(HarnessError::Invalid(
                "duplicate tool call identity; no action was repeated".into(),
            ));
        }
        if self.calls.len() >= 256 {
            return Err(HarnessError::RecoveryExhausted);
        }
        self.calls.insert(call_id.as_str().into());
        let parsed = parse_tool(name, args.clone())?;
        let changes_target_or_input = matches!(
            parsed,
            ToolCall::Ax(_)
                | ToolCall::SetText(_)
                | ToolCall::Press(_)
                | ToolCall::Fill(_)
                | ToolCall::Click(_)
                | ToolCall::GroundClick(_)
                | ToolCall::Pointer(_)
                | ToolCall::Keypress(_)
                | ToolCall::Type(_)
                | ToolCall::Open(_)
        );
        if changes_target_or_input && self.outcome_counts().0 > 0 {
            return Err(HarnessError::PendingOutcome);
        }
        if matches!(
            parsed,
            ToolCall::Ax(_)
                | ToolCall::SetText(_)
                | ToolCall::Press(_)
                | ToolCall::Fill(_)
                | ToolCall::Click(_)
                | ToolCall::GroundClick(_)
                | ToolCall::Pointer(_)
                | ToolCall::Keypress(_)
                | ToolCall::Type(_)
        ) && self.operations.len() >= 64
        {
            return Err(HarnessError::RecoveryExhausted);
        }
        let global = matches!(
            parsed,
            ToolCall::GroundClick(_)
                | ToolCall::Click(_)
                | ToolCall::Pointer(_)
                | ToolCall::Keypress(_)
                | ToolCall::Type(_)
        );
        if global
            && (self.policy != InteractionPolicy::Foreground
                || scope.policy != InteractionPolicy::Foreground)
        {
            return Err(HarnessError::Policy);
        }
        if matches!(parsed, ToolCall::Capture(_)) && self.browser_model {
            return Err(HarnessError::Capability("This browser model has no image attachment transport. Use text and Accessibility observations.".into()));
        }
        let call = self.canonicalize(parsed)?;
        match call{
            ToolCall::Status=>Ok(ToolOutput::text(json!({"permissions":self.backend.permissions(),"bound":self.binding.is_some(),"interaction_policy":self.policy}).to_string(),true)),
            ToolCall::Apps(args)=>{
                if args.query.as_ref().is_some_and(|q|q.trim().is_empty()||q.chars().count()>200){return Err(HarnessError::Invalid("query".into()))}
                let query=args.query.as_ref().map(|q|q.to_lowercase());let mut apps=self.backend.applications()?;apps.retain(|a|!a.is_terminated&&a.process_identifier>0&&query.as_ref().map_or(a.activation_policy==0||a.is_active,|q|a.localized_name.as_ref().is_some_and(|n|n.to_lowercase().contains(q))||a.bundle_identifier.as_ref().is_some_and(|n|n.to_lowercase().contains(q))));apps.sort_by(|a,b|b.is_active.cmp(&a.is_active).then(a.localized_name.cmp(&b.localized_name)));
                let matched=apps.len();let mut text=String::new();let mut returned=0;for app in apps{let row=json!({"pid":app.process_identifier,"name":app.localized_name,"bundle_id":app.bundle_identifier,"active":app.is_active}).to_string();if text.len()+row.len()+1>3100{continue}text.push_str(&row);text.push('\n');returned+=1}Ok(ToolOutput::text(format!("APPS scope={} matched={matched} returned={returned} omitted={}\n{text}",if query.is_some(){"all_matching_running_apps"}else{"user_facing"},matched-returned),true))
            },
            ToolCall::Open(args)=>{
                if args.bundle_id.is_empty()||args.bundle_id.len()>255||!args.bundle_id.chars().all(|c|c.is_alphanumeric()||c=='.'||c=='-'){return Err(HarnessError::Invalid("bundle_id".into()))}
                if args.activation==ActivationMode::Foreground&&self.policy!=InteractionPolicy::Foreground{return Err(HarnessError::Policy)}
                if args.activation==ActivationMode::None&&args.url.is_some(){return Err(HarnessError::Policy)}
                self.approve(scope,call_id,"Application action",format!("Application: {}\nActivation: {:?}\nURL: {}",args.bundle_id,args.activation,json!(args.url)),cancel,approval).await?;
                self.check(scope,cancel)?;let authority=self.authority.clone();let token=cancel.clone();let mut before=move||{authority.check().map_err(|_|AutomationError::Cancelled)?;if token.is_cancelled(){return Err(AutomationError::Cancelled)}Ok(())};let binding=self.backend.open(&args.bundle_id,args.activation==ActivationMode::Foreground,args.url.as_deref(),&mut before).await?;self.check(scope,cancel)?;
                self.clear_observations();self.binding=Some(binding.clone());Ok(ToolOutput::text(format!("BOUND_APPLICATION pid={} bundle_id={} activation={} window={}\nNative reads/actions require fresh observed references. Binding itself grants no input authority.",binding.application.process_identifier,args.bundle_id,if binding.activated{"foreground"}else{"none"},binding.window.title.as_deref().unwrap_or("unknown")),true))
            },
            ToolCall::Snapshot(args)=>{
                let binding=self.binding()?;self.backend.validate(&binding)?;
                if let Some(cursor)=&args.cursor{let cursor=uuid(cursor)?;let publication=self.reader.continue_read(cursor,Some(&args),binding.generation,16384)?;self.check(scope,cancel)?;self.backend.validate(&binding)?;return Ok(self.emit_read(publication))}
                let previous=self.publication.as_ref();let snapshot=if let(Some(id),Some(index))=(&args.snapshot_id,args.element_index){let(snapshot,_)=self.current(id,index)?;snapshot}else{self.backend.observe(&binding,TreeLimits::default())?};
                let exposed=previous.map(|p|p.exposed.clone());let publication=self.reader.start(snapshot,args,exposed.as_ref(),16384)?;self.check(scope,cancel)?;self.backend.validate(&binding)?;Ok(self.emit_read(publication))
            },
            ToolCall::Continue(args)=>{let binding=self.binding()?;self.backend.validate(&binding)?;let publication=self.reader.continue_read(uuid(&args.cursor)?,None,binding.generation,16384)?;self.check(scope,cancel)?;self.backend.validate(&binding)?;Ok(self.emit_read(publication))},
            ToolCall::SetText(args)=>{if args.text.len()>4096||args.text.contains('\0'){return Err(HarnessError::Invalid("field text".into()))};self.semantic_mutation(scope,call_id,&args.snapshot_id,args.element_index,SemanticMutation::SetText(args.text.clone()),NativeMutation::SetValue(args.text),None,cancel,approval).await},
            ToolCall::Ax(args)=>{if args.ax_action==AxAction::Raise&&self.policy==InteractionPolicy::BackgroundOnly{return Err(HarnessError::Policy)}let mutation=if args.ax_action==AxAction::Press{SemanticMutation::Press}else{SemanticMutation::OtherAction(args.ax_action.as_str().into())};self.semantic_mutation(scope,call_id,&args.snapshot_id,args.element_index,mutation,NativeMutation::Action(args.ax_action.as_str().into()),args.postcondition.as_ref(),cancel,approval).await},
            ToolCall::Capture(args)=>{
                let binding=self.binding()?;if args.display_id==Some(0){return Err(HarnessError::Invalid("display_id".into()))}
                if (args.display_id.is_some() || args.shows_cursor) && (self.policy!=InteractionPolicy::Foreground || !binding.activated) {return Err(HarnessError::Policy)}
                let mut image=self.backend.capture(&binding,args.display_id,args.shows_cursor).await?;self.check(scope,cancel)?;self.backend.validate(&binding)?;image.actionable&=self.policy==InteractionPolicy::Foreground&&binding.activated;let id=image.id;
                let mut output=ToolOutput{content:vec![ContentItem::Text{text:format!("{}{} observation_id={} image_width={} image_height={} coordinate_space=image_pixels actionable={}\nThis image is an observation; background captures grant no input authority.",if args.display_id.is_some(){"DISPLAY_CAPTURE"}else if image.actionable{"WINDOW_CAPTURE"}else{"WINDOW_OBSERVATION"},if image.actionable{format!(" capture_id={id}")}else{String::new()},id,image.width,image.height,image.actionable)},ContentItem::Image{image_url:format!("data:image/png;base64,{}",STANDARD.encode(&image.png))}],success:true};
                self.publication=None;self.reader.invalidate();self.capture_cursor=args.shows_cursor;self.capture_display=args.display_id;self.capture=Some(image);
                if args.include_accessibility{let snapshot=self.backend.observe(&binding,TreeLimits::default())?;let captured=&self.capture.as_ref().unwrap().window;if snapshot.window.window_id!=captured.window_id||snapshot.window.process_identifier!=captured.process_identifier||snapshot.window.document!=captured.document||snapshot.window.frame!=captured.frame{self.clear_observations();return Err(HarnessError::Native(AutomationError::TargetChanged))}let publication=self.reader.start(snapshot,ReadArgs::default(),None,16384)?;output.content.push(ContentItem::Text{text:format!("SYNCHRONIZED_AX observation_id={id}\n{}",publication.text)});self.publication=Some(publication)}Ok(output)
            },
            ToolCall::GroundClick(args)=>{
                validate_text(&args.target,512)?;if args.target.trim()!=args.target||args.target.chars().any(char::is_control){return Err(HarnessError::Invalid("target".into()))}let image=self.capture.as_ref().ok_or(HarnessError::StaleReference)?.clone();if uuid(&args.capture_id)?!=image.id||!image.actionable{return Err(HarnessError::StaleReference)}
                let decision=grounder.locate(&image,&args.target,cancel).await?;self.check(scope,cancel)?;validate_grounding(&decision,&image)?;
                self.pointer(scope,call_id,&args.capture_id,decision.point,InputAction::Click(decision.point),cancel,approval).await
            },
            ToolCall::Click(args)=>{let p=Point{x:args.x,y:args.y};self.pointer(scope,call_id,&args.capture_id,p,InputAction::Click(p),cancel,approval).await},
            ToolCall::Pointer(args)=>{
                let p=Point{x:args.x,y:args.y};let action=match args.action{PointerAction::Move=>InputAction::Move(p),PointerAction::DoubleClick=>InputAction::DoubleClick(p),PointerAction::RightClick=>InputAction::RightClick(p),PointerAction::Scroll=>{let(dx,dy)=(args.delta_x.ok_or_else(||HarnessError::Invalid("delta_x".into()))?,args.delta_y.ok_or_else(||HarnessError::Invalid("delta_y".into()))?);if !dx.is_finite()||!dy.is_finite()||dx.abs()>10000.||dy.abs()>10000.{return Err(HarnessError::Invalid("scroll delta".into()))}InputAction::Scroll{point:p,delta_x:dx,delta_y:dy}}};self.pointer(scope,call_id,&args.capture_id,p,action,cancel,approval).await
            },
            ToolCall::Keypress(args)=>{if args.key.is_empty()||args.key.len()>64||args.modifiers.len()>5||args.modifiers.iter().enumerate().any(|(i,m)|args.modifiers[..i].contains(m)){return Err(HarnessError::Invalid("key chord".into()))}let modifiers=args.modifiers.iter().map(|m|serde_json::to_value(m).unwrap().as_str().unwrap().to_owned()).collect();self.global_input(scope,call_id,InputAction::Key{key:args.key,modifiers},cancel,approval).await},
            ToolCall::Type(args)=>{validate_text(&args.text,4096)?;self.global_input(scope,call_id,InputAction::Type(args.text),cancel,approval).await},
            ToolCall::Verify(args)=>self.verify_receipt(scope,&args,cancel),
            _=>Err(HarnessError::Invalid("noncanonical tool dispatch".into())),
        }
    }
    async fn approve(
        &self,
        scope: &ExecutionScope,
        call_id: &Identifier,
        title: &str,
        details: String,
        cancel: &CancellationToken,
        gate: &mut dyn ApprovalGate,
    ) -> Result<(), HarnessError> {
        self.check(scope, cancel)?;
        let approval = NativeApproval {
            id: format!("computer:{}:{}", scope.generation, call_id.as_str()),
            task_id: scope.task_id.clone(),
            title: title.into(),
            summary: details.clone(),
            details,
        };
        let approved = tokio::select! {_ = cancel.cancelled()=>return Err(HarnessError::Cancelled),result=gate.approve(approval)=>result?};
        self.check(scope, cancel)?;
        if !approved {
            return Err(HarnessError::Declined);
        }
        Ok(())
    }
    // The action and its original verification plan remain distinct values.
    #[allow(clippy::too_many_arguments)]
    async fn semantic_mutation(
        &mut self,
        scope: &ExecutionScope,
        call_id: &Identifier,
        snapshot_id: &str,
        index: usize,
        mutation: SemanticMutation,
        native: NativeMutation,
        request: Option<&Postcondition>,
        cancel: &CancellationToken,
        approval: &mut dyn ApprovalGate,
    ) -> Result<ToolOutput, HarnessError> {
        let binding = self.binding()?;
        let (snapshot, exposed) = self.current(snapshot_id, index)?;
        let selected = snapshot.node(index)?;
        match &native {
            NativeMutation::Action(action) if !selected.has_action(action) => {
                return Err(HarnessError::Native(AutomationError::UnsupportedAction));
            }
            NativeMutation::SetValue(_) if !selected.is_value_settable => {
                return Err(HarnessError::Native(AutomationError::NotSettable));
            }
            _ => {}
        }
        let plan = VerificationPlan::compile(request, &mutation, index, &snapshot, &exposed)?;
        let key = format!(
            "{}:{}:{}",
            binding.generation,
            plan.action.token,
            serde_json::to_string(&mutation).unwrap()
        );
        if self.failures.get(&key).copied().unwrap_or(0) >= 3 {
            return Err(HarnessError::RecoveryExhausted);
        }
        if self.operations.len() >= 64 {
            return Err(HarnessError::RecoveryExhausted);
        }
        let id = Uuid::new_v4();
        let receipt = ActionReceipt {
            operation_id: id,
            call_id: call_id.as_str().into(),
            dispatch: DispatchState::NotDispatched,
            status: if plan.baseline_satisfied {
                "already_satisfied"
            } else {
                "pending"
            }
            .into(),
            verified: None,
            verification_reads: 0,
            plan: Some(plan.clone()),
            failure: None,
            legacy_baseline: None,
        };
        self.operations.insert(id, receipt);
        if plan.baseline_satisfied {
            return Ok(ToolOutput::text(
                format!(
                    "ALREADY_SATISFIED operation_id={id} dispatch=not_dispatched property={} expected={}\nNo input occurred. This establishes only the declared property.",
                    serde_json::to_value(plan.kind).unwrap(),
                    json!(plan.expected)
                ),
                true,
            ));
        }
        if let Err(error) = self
            .approve(
                scope,
                call_id,
                "Computer action",
                format!(
                    "Application: {}\nTarget: {}\nAction: {:?}\nExpected: {}",
                    binding
                        .application
                        .localized_name
                        .as_deref()
                        .unwrap_or("unknown"),
                    selected.label(),
                    mutation,
                    plan.expected
                ),
                cancel,
                approval,
            )
            .await
        {
            let receipt = self.operations.get_mut(&id).unwrap();
            receipt.status = "rejected_before_dispatch".into();
            receipt.failure = Some(error.to_string());
            return Err(error);
        }
        self.check(scope, cancel)?;
        self.backend.validate(&binding)?;
        let fresh = self.backend.observe(&binding, TreeLimits::default())?;
        let target = plan.revalidate(&fresh)?;
        self.check(scope, cancel)?;
        let authority = self.authority.clone();
        let token = cancel.clone();
        let began = std::cell::Cell::new(false);
        let mut before = || {
            authority.check().map_err(|_| AutomationError::Cancelled)?;
            if token.is_cancelled() {
                return Err(AutomationError::Cancelled);
            }
            began.set(true);
            Ok(())
        };
        self.clear_observations();
        let result = self.backend.mutate(&binding, target, native, &mut before);
        let receipt = self.operations.get_mut(&id).unwrap();
        receipt.dispatch = if result.is_ok() {
            DispatchState::Dispatched
        } else if began.get() {
            DispatchState::DeliveryUncertain
        } else {
            DispatchState::NotDispatched
        };
        receipt.status = if began.get() {
            "verification_pending"
        } else {
            "rejected_before_dispatch"
        }
        .into();
        if let Err(error) = result {
            receipt.failure = Some(error.to_string());
            *self.failures.entry(key).or_default() += 1;
            return Ok(ToolOutput::text(
                format!(
                    "ACTION_EVIDENCE operation_id={id} dispatch={} status={}\n{error}\nNo action was repeated.{}",
                    serde_json::to_value(&receipt.dispatch)
                        .unwrap()
                        .as_str()
                        .unwrap(),
                    receipt.status,
                    if began.get() {
                        " Outcome remains unverified; only read-only recovery is permitted."
                    } else {
                        " No input occurred."
                    }
                ),
                false,
            ));
        }
        self.check(scope, cancel)?;
        for _ in 0..3 {
            self.backend.validate(&binding)?;
            let observation = self.backend.observe(&binding, TreeLimits::default())?;
            self.check(scope, cancel)?;
            self.operations.get_mut(&id).unwrap().verification_reads += 1;
            if let Ok(proof) = plan.evaluate(&observation) {
                let receipt = self.operations.get_mut(&id).unwrap();
                receipt.status = "verified".into();
                receipt.verified = Some(proof.clone());
                self.failures.remove(&key);
                let publication =
                    self.reader
                        .start(observation, ReadArgs::default(), None, 16384)?;
                let read = self.emit_read(publication);
                let mut content = vec![ContentItem::Text {
                    text: format!(
                        "VERIFIED_PROPERTY operation_id={id} property={} expected={} observation_id={}\nThis proves only the declared property; read actual content before claiming task completion.",
                        proof.property,
                        json!(proof.expected_value),
                        proof.observation_id
                    ),
                }];
                content.extend(read.content);
                return Ok(ToolOutput {
                    content,
                    success: true,
                });
            }
            tokio::select! {_ = cancel.cancelled()=>return Err(HarnessError::Cancelled),_ = tokio::time::sleep(std::time::Duration::from_millis(120))=>{}};
        }
        *self.failures.entry(key).or_default() += 1;
        Ok(ToolOutput::text(
            format!(
                "ACTION_EVIDENCE operation_id={id} dispatch=dispatched status=verification_pending\nThe intended property was not observed in bounded fresh reads. No action was repeated. Outcome remains unverified."
            ),
            false,
        ))
    }
    fn verify_receipt(
        &mut self,
        scope: &ExecutionScope,
        args: &VerifyArgs,
        cancel: &CancellationToken,
    ) -> Result<ToolOutput, HarnessError> {
        let id = uuid(&args.operation_id)?;
        let receipt = self
            .operations
            .get(&id)
            .ok_or(HarnessError::StaleReference)?
            .clone();
        if receipt.verified.is_some()
            || receipt.dispatch == DispatchState::NotDispatched
                && matches!(
                    receipt.status.as_str(),
                    "already_satisfied" | "rejected_before_dispatch"
                )
        {
            return Ok(ToolOutput::text(
                format!(
                    "HISTORICAL_ACTION_STATUS operation_id={id} status={} live_observation=false\nNo read, input or replay occurred. Supplied property/expected values and current state were not verified.",
                    if receipt.verified.is_some() {
                        "original_property_verified"
                    } else {
                        "not_performed"
                    }
                ),
                true,
            ));
        }
        if receipt.plan.is_none() {
            if receipt.dispatch == DispatchState::NotDispatched {
                return Err(HarnessError::StaleReference);
            }
            let (snapshot_id,index,property,expected)=match (&args.snapshot_id,args.element_index,&args.property,&args.expected) {
                (Some(id),Some(index),Some(property),Some(expected))=>(id,index,property,expected),
                _=>return Err(HarnessError::Invalid("Unplanned native input verification requires the current snapshot_id, element_index, property=text|value and exact expected value.".into()))
            };
            let publication = self
                .publication
                .as_ref()
                .ok_or(HarnessError::StaleReference)?
                .clone();
            self.current(snapshot_id, index)?;
            let baseline = receipt
                .legacy_baseline
                .ok_or(HarnessError::Verification(VerificationError::Incomplete))?;
            if receipt.verification_reads >= 5 {
                return Err(HarnessError::RecoveryExhausted);
            }
            let binding = self.binding()?;
            self.check(scope, cancel)?;
            self.backend.validate(&binding)?;
            self.operations.get_mut(&id).unwrap().verification_reads += 1;
            let observation = self.backend.observe(&binding, TreeLimits::default())?;
            self.check(scope, cancel)?;
            let proof = baseline.verify(
                &publication,
                index,
                property,
                expected,
                &observation,
                &binding,
            )?;
            let receipt = self.operations.get_mut(&id).unwrap();
            receipt.verified = Some(proof.clone());
            receipt.status = "verified".into();
            let publication = self
                .reader
                .start(observation, ReadArgs::default(), None, 16384)?;
            let read = self.emit_read(publication);
            let mut content = vec![ContentItem::Text {
                text: format!(
                    "VERIFIED_PROPERTY operation_id={id} property={} expected={} observation_id={}\nThis reconciles only the changed rendered property on the same observed control; it does not prove the whole task. No input was repeated.",
                    proof.property,
                    json!(proof.expected_value),
                    proof.observation_id
                ),
            }];
            content.extend(read.content);
            return Ok(ToolOutput {
                content,
                success: true,
            });
        }
        if args.snapshot_id.is_some() || args.element_index.is_some() || args.property.is_some() {
            return Err(HarnessError::Invalid(
                "Verification uses only its original host-owned plan.".into(),
            ));
        }
        let plan = receipt.plan.unwrap();
        if args.expected.as_ref().is_some_and(|e| e != &plan.expected) {
            return Err(HarnessError::Invalid(
                "verification cannot replace original expected result".into(),
            ));
        }
        if receipt.verification_reads >= 5 {
            return Err(HarnessError::RecoveryExhausted);
        }
        let binding = self.binding()?;
        self.check(scope, cancel)?;
        let observation = self.backend.observe(&binding, TreeLimits::default())?;
        self.operations.get_mut(&id).unwrap().verification_reads += 1;
        self.check(scope, cancel)?;
        let proof = plan.evaluate(&observation)?;
        let receipt = self.operations.get_mut(&id).unwrap();
        receipt.verified = Some(proof.clone());
        receipt.status = "verified".into();
        Ok(ToolOutput::text(
            format!(
                "VERIFIED_PROPERTY operation_id={id} property={} expected={} observation_id={}",
                proof.property,
                json!(proof.expected_value),
                proof.observation_id
            ),
            true,
        ))
    }
    #[allow(clippy::too_many_arguments)]
    async fn pointer(
        &mut self,
        scope: &ExecutionScope,
        call_id: &Identifier,
        capture_id: &str,
        image_point: Point,
        action: InputAction,
        cancel: &CancellationToken,
        approval: &mut dyn ApprovalGate,
    ) -> Result<ToolOutput, HarnessError> {
        let capture = self
            .capture
            .as_ref()
            .ok_or(HarnessError::StaleReference)?
            .clone();
        if !capture.actionable {
            return Err(HarnessError::Policy);
        }
        let point = ScreenshotCoordinateMapper::new(&capture)?.screen_point(
            uuid(capture_id)?,
            image_point.x,
            image_point.y,
            unix_time(),
            600.,
        )?;
        let action = match action {
            InputAction::Click(_) => InputAction::Click(point),
            InputAction::Move(_) => InputAction::Move(point),
            InputAction::DoubleClick(_) => InputAction::DoubleClick(point),
            InputAction::RightClick(_) => InputAction::RightClick(point),
            InputAction::Scroll {
                delta_x, delta_y, ..
            } => InputAction::Scroll {
                point,
                delta_x,
                delta_y,
            },
            _ => return Err(HarnessError::Invalid("pointer action".into())),
        };
        let binding = self.binding()?;
        self.approve(
            scope,
            call_id,
            "Computer pointer action",
            format!(
                "Application: {}\nAction: {:?}\nCapture: {capture_id}",
                binding
                    .application
                    .localized_name
                    .as_deref()
                    .unwrap_or("unknown"),
                action
            ),
            cancel,
            approval,
        )
        .await?;
        self.check(scope, cancel)?;
        self.backend.validate(&binding)?;
        let fresh = self
            .backend
            .capture(&binding, self.capture_display, self.capture_cursor)
            .await?;
        self.check(scope, cancel)?;
        if fresh.width != capture.width
            || fresh.height != capture.height
            || fresh.frame != capture.frame
            || Sha256::digest(&fresh.png) != Sha256::digest(&capture.png)
        {
            return Err(HarnessError::Native(AutomationError::TargetChanged));
        }
        self.dispatch_global(scope, call_id, &binding, action, cancel)
            .await
    }
    async fn global_input(
        &mut self,
        scope: &ExecutionScope,
        call_id: &Identifier,
        action: InputAction,
        cancel: &CancellationToken,
        approval: &mut dyn ApprovalGate,
    ) -> Result<ToolOutput, HarnessError> {
        let binding = self.binding()?;
        if !binding.activated {
            return Err(HarnessError::Policy);
        }
        self.approve(
            scope,
            call_id,
            "Computer keyboard action",
            format!(
                "Application: {}\nAction: {:?}",
                binding
                    .application
                    .localized_name
                    .as_deref()
                    .unwrap_or("unknown"),
                action
            ),
            cancel,
            approval,
        )
        .await?;
        self.dispatch_global(scope, call_id, &binding, action, cancel)
            .await
    }
    async fn dispatch_global(
        &mut self,
        scope: &ExecutionScope,
        call_id: &Identifier,
        binding: &BoundApplication,
        action: InputAction,
        cancel: &CancellationToken,
    ) -> Result<ToolOutput, HarnessError> {
        self.check(scope, cancel)?;
        let legacy_baseline = if let Some(publication) = self.publication.as_ref() {
            self.backend
                .observe(binding, TreeLimits::default())
                .ok()
                .and_then(|fresh| LegacyBaseline::capture(publication, &fresh, binding))
        } else {
            None
        };
        self.check(scope, cancel)?;
        self.backend.validate(binding)?;
        let authority = self.authority.clone();
        let token = cancel.clone();
        let began = std::cell::Cell::new(false);
        let mut before = || {
            authority.check().map_err(|_| AutomationError::Cancelled)?;
            if token.is_cancelled() {
                return Err(AutomationError::Cancelled);
            }
            began.set(true);
            Ok(())
        };
        self.clear_observations();
        let id = Uuid::new_v4();
        let result = self.backend.input(binding, action, &mut before);
        let dispatch = if result.is_ok() {
            DispatchState::Dispatched
        } else if began.get() {
            DispatchState::DeliveryUncertain
        } else {
            DispatchState::NotDispatched
        };
        let status = if began.get() {
            "verification_pending"
        } else {
            "rejected_before_dispatch"
        };
        self.operations.insert(
            id,
            ActionReceipt {
                operation_id: id,
                call_id: call_id.as_str().into(),
                dispatch: dispatch.clone(),
                status: status.into(),
                verified: None,
                verification_reads: 0,
                plan: None,
                failure: result.as_ref().err().map(ToString::to_string),
                legacy_baseline,
            },
        );
        let mut output = ToolOutput::text(
            format!(
                "ACTION_EVIDENCE operation_id={id} dispatch={} status={status}\nGlobal input dispatch is not proof of the intended outcome. A post-action observation cannot replace a predeclared result.{}",
                serde_json::to_value(dispatch).unwrap().as_str().unwrap(),
                result
                    .as_ref()
                    .err()
                    .map(|e| format!("\n{e}"))
                    .unwrap_or_default()
            ),
            false,
        );
        if began.get()
            && self.check(scope, cancel).is_ok()
            && self.backend.validate(binding).is_ok()
        {
            if let Ok(snapshot) = self.backend.observe(binding, TreeLimits::default()) {
                let publication = self
                    .reader
                    .start(snapshot, ReadArgs::default(), None, 16384)?;
                output.content.push(ContentItem::Text {
                    text: publication.text.clone(),
                });
                self.publication = Some(publication);
            }
            if !self.browser_model
                && self.backend.permissions().screen_recording
                    == computa_macos::PermissionGrant::Granted
                && let Ok(image) = self.backend.capture(binding, None, false).await
                && self.check(scope, cancel).is_ok()
                && self.backend.validate(binding).is_ok()
            {
                output.content.push(ContentItem::Text{text:format!("POST_ACTION_CAPTURE observation_id={} image_width={} image_height={} actionable=false\nThis screenshot is a fresh verification observation and grants no reusable input authority. Verify the exact operation_id against an observed changed property.",image.id,image.width,image.height)});
                output.content.push(ContentItem::Image {
                    image_url: format!("data:image/png;base64,{}", STANDARD.encode(&image.png)),
                });
                // A post-action image can explain an uncertain outcome,
                // but cannot become the next pointer's authority.
                self.capture = None;
            }
        }
        Ok(output)
    }
}
fn uuid(value: &str) -> Result<Uuid, HarnessError> {
    Uuid::parse_str(value).map_err(|_| HarnessError::Invalid("UUID reference".into()))
}
fn validate_text(text: &str, maximum: usize) -> Result<(), HarnessError> {
    if text.is_empty() || text.len() > maximum || text.contains('\0') {
        return Err(HarnessError::Invalid("text length or NUL".into()));
    }
    Ok(())
}
pub fn validate_grounding(
    decision: &QualifiedGrounding,
    image: &CapturedImage,
) -> Result<(), HarnessError> {
    if decision.capture_id != image.id
        || decision.model_points.len() < 2
        || decision.model_points.len() > 3
        || !decision.point.x.is_finite()
        || !decision.point.y.is_finite()
        || decision.point.x < 0.
        || decision.point.y < 0.
        || decision.point.x >= image.width as f64
        || decision.point.y >= image.height as f64
    {
        return Err(HarnessError::Invalid("grounding decision".into()));
    }
    let names: HashSet<_> = decision
        .model_points
        .iter()
        .map(|(n, _)| n.as_str())
        .collect();
    if names
        .iter()
        .any(|name| !matches!(*name, "goclick-base-4bit" | "gui-owl-2b" | "showui-2b-4bit"))
        || decision.method == GroundingMethod::GoClickGuiOwlAgreement
            && (!names.contains("goclick-base-4bit") || !names.contains("gui-owl-2b"))
        || decision.method == GroundingMethod::ShowUiDisambiguated
            && !names.contains("showui-2b-4bit")
    {
        return Err(HarnessError::Capability("Grounding requires the qualified GoClick/GUI-Owl cascade; a single model point is not sufficient.".into()));
    }
    if names.len() != decision.model_points.len()
        || decision.model_points.iter().any(|(_, p)| {
            !p.x.is_finite()
                || !p.y.is_finite()
                || p.x < 0.
                || p.y < 0.
                || p.x >= image.width as f64
                || p.y >= image.height as f64
        })
    {
        return Err(HarnessError::Invalid("grounding model point".into()));
    }
    let goclick = decision
        .model_points
        .iter()
        .find(|(n, _)| n == "goclick-base-4bit")
        .map(|(_, p)| *p);
    let gui = decision
        .model_points
        .iter()
        .find(|(n, _)| n == "gui-owl-2b")
        .map(|(_, p)| *p);
    let diagonal = (image.width as f64).hypot(image.height as f64);
    let distance = |a: Point, b: Point| (a.x - b.x).hypot(a.y - b.y);
    let initial_pixels = goclick.zip(gui).map(|(a, b)| distance(a, b));
    let use_show = initial_pixels.is_none_or(|distance| distance > 0.03 * diagonal);
    if use_show != (decision.method == GroundingMethod::ShowUiDisambiguated)
        || !use_show && decision.model_points.len() != 2
    {
        return Err(HarnessError::Invalid(
            "grounding cascade routing evidence".into(),
        ));
    }
    let (first, second) = if use_show {
        let mut pairs = vec![];
        for (i, (_, a)) in decision.model_points.iter().enumerate() {
            for (_, b) in decision.model_points.iter().skip(i + 1) {
                pairs.push((*a, *b));
            }
        }
        pairs
            .into_iter()
            .min_by(|(a, b), (c, d)| distance(*a, *b).total_cmp(&distance(*c, *d)))
            .unwrap()
    } else {
        (goclick.unwrap(), gui.unwrap())
    };
    let midpoint = Point {
        x: (first.x + second.x) / 2.,
        y: (first.y + second.y) / 2.,
    };
    if distance(first, second) > 0.03 * diagonal || distance(midpoint, decision.point) > 1e-6 {
        return Err(HarnessError::Invalid(
            "grounding models did not agree on the declared midpoint".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::semantic::fixtures;
    use computa_macos::{
        DisplayInfo, PermissionGrant, PermissionSnapshot, Rect, RunningApplication, WindowInfo,
    };
    use std::{cell::RefCell, rc::Rc};
    #[derive(Clone, Copy)]
    enum MutationBehavior {
        Normal,
        RejectBeforeDispatch,
        LostAcknowledgement,
    }
    struct FakeState {
        snapshot: AxSnapshot,
        binding: Option<BoundApplication>,
        mutations: usize,
        inputs: usize,
        prompts: usize,
        captures: Vec<Option<u32>>,
        behavior: MutationBehavior,
    }
    struct FakeBackend(Rc<RefCell<FakeState>>);
    impl MacosBackend for FakeBackend {
        fn permissions(&self) -> PermissionSnapshot {
            PermissionSnapshot {
                accessibility: PermissionGrant::Granted,
                screen_recording: PermissionGrant::Granted,
            }
        }
        fn request_accessibility(&self) -> PermissionSnapshot {
            self.0.borrow_mut().prompts += 1;
            self.permissions()
        }
        fn request_screen_recording(&self) -> PermissionSnapshot {
            self.0.borrow_mut().prompts += 1;
            self.permissions()
        }
        fn applications(&self) -> computa_macos::Result<Vec<RunningApplication>> {
            Ok(vec![app()])
        }
        fn bind(
            &mut self,
            _bundle: &str,
            activate: bool,
            _url: Option<&str>,
        ) -> computa_macos::Result<BoundApplication> {
            let mut state = self.0.borrow_mut();
            let binding = BoundApplication {
                application: app(),
                window: state.snapshot.window.clone(),
                window_token: Uuid::new_v4(),
                generation: state.snapshot.target_generation,
                activated: activate,
            };
            state.binding = Some(binding.clone());
            Ok(binding)
        }
        fn validate(&self, binding: &BoundApplication) -> computa_macos::Result<()> {
            if self.0.borrow().binding.as_ref() == Some(binding) {
                Ok(())
            } else {
                Err(AutomationError::TargetChanged)
            }
        }
        fn observe(
            &mut self,
            binding: &BoundApplication,
            _limits: TreeLimits,
        ) -> computa_macos::Result<AxSnapshot> {
            self.validate(binding)?;
            let mut snapshot = self.0.borrow().snapshot.clone();
            snapshot.id = Uuid::new_v4();
            Ok(snapshot)
        }
        fn mutate(
            &mut self,
            binding: &BoundApplication,
            element: Uuid,
            mutation: NativeMutation,
            before: &mut dyn FnMut() -> computa_macos::Result<()>,
        ) -> computa_macos::Result<()> {
            self.validate(binding)?;
            if matches!(
                self.0.borrow().behavior,
                MutationBehavior::RejectBeforeDispatch
            ) {
                return Err(AutomationError::StaleObservation);
            }
            before()?;
            let mut state = self.0.borrow_mut();
            state.mutations += 1;
            let node = state
                .snapshot
                .elements
                .iter_mut()
                .find(|n| n.identity == element)
                .ok_or(AutomationError::StaleObservation)?;
            if let NativeMutation::SetValue(text) = mutation {
                node.value = Some(text)
            }
            if matches!(state.behavior, MutationBehavior::LostAcknowledgement) {
                return Err(AutomationError::Native {
                    operation: "AXMutation".into(),
                    code: -25204,
                });
            }
            Ok(())
        }
        fn capture<'a>(
            &'a mut self,
            binding: &'a BoundApplication,
            display: Option<u32>,
            _cursor: bool,
        ) -> Pin<Box<dyn Future<Output = computa_macos::Result<CapturedImage>> + 'a>> {
            Box::pin(async move {
                self.validate(binding)?;
                self.0.borrow_mut().captures.push(display);
                Ok(image(binding.window.clone()))
            })
        }
        fn input(
            &mut self,
            binding: &BoundApplication,
            _action: InputAction,
            before: &mut dyn FnMut() -> computa_macos::Result<()>,
        ) -> computa_macos::Result<()> {
            self.validate(binding)?;
            before()?;
            self.0.borrow_mut().inputs += 1;
            Ok(())
        }
        fn displays(&self) -> computa_macos::Result<Vec<DisplayInfo>> {
            Ok(vec![])
        }
        fn invalidate(&mut self) {
            self.0.borrow_mut().binding = None
        }
    }
    fn app() -> RunningApplication {
        RunningApplication {
            process_identifier: 7,
            bundle_identifier: Some("test.app".into()),
            localized_name: Some("Test".into()),
            is_active: false,
            is_terminated: false,
            activation_policy: 0,
            launch_time: Some(1.),
        }
    }
    fn scope() -> ExecutionScope {
        ExecutionScope {
            task_id: Identifier::new("task").unwrap(),
            thread_id: Identifier::new("thread").unwrap(),
            turn_id: Identifier::new("turn").unwrap(),
            generation: Uuid::new_v4(),
            policy: InteractionPolicy::BackgroundOnly,
        }
    }
    fn call(s: &str) -> Identifier {
        Identifier::new(s).unwrap()
    }
    fn image(window: WindowInfo) -> CapturedImage {
        CapturedImage {
            id: Uuid::new_v4(),
            png: vec![1],
            width: 100,
            height: 100,
            frame: Rect {
                x: 0.,
                y: 0.,
                width: 100.,
                height: 100.,
            },
            captured_at: unix_time(),
            window,
            actionable: false,
        }
    }
    struct Allow;
    impl ApprovalGate for Allow {
        fn approve<'a>(
            &'a mut self,
            _request: NativeApproval,
        ) -> LocalFuture<'a, Result<bool, HarnessError>> {
            Box::pin(async { Ok(true) })
        }
    }
    struct CancelApproval(CancellationToken);
    impl ApprovalGate for CancelApproval {
        fn approve<'a>(
            &'a mut self,
            _request: NativeApproval,
        ) -> LocalFuture<'a, Result<bool, HarnessError>> {
            Box::pin(async move {
                self.0.cancel();
                Ok(true)
            })
        }
    }
    struct ChangeApproval(Rc<RefCell<FakeState>>);
    impl ApprovalGate for ChangeApproval {
        fn approve<'a>(
            &'a mut self,
            _request: NativeApproval,
        ) -> LocalFuture<'a, Result<bool, HarnessError>> {
            Box::pin(async move {
                self.0.borrow_mut().snapshot.elements[0].value =
                    Some("another user changed it".into());
                Ok(true)
            })
        }
    }
    fn setup() -> (
        Harness<FakeBackend>,
        Rc<RefCell<FakeState>>,
        ExecutionScope,
        CancellationToken,
    ) {
        let state = Rc::new(RefCell::new(FakeState {
            snapshot: fixtures::snapshot("old"),
            binding: None,
            mutations: 0,
            inputs: 0,
            prompts: 0,
            captures: vec![],
            behavior: MutationBehavior::Normal,
        }));
        let mut harness = Harness::new(
            FakeBackend(state.clone()),
            InteractionPolicy::BackgroundOnly,
        );
        let scope = scope();
        harness.begin_turn(scope.clone()).unwrap();
        (harness, state, scope, CancellationToken::new())
    }
    #[tokio::test]
    async fn background_capture_cannot_collect_display_or_pointer_context() {
        let (mut harness, state, scope, cancel) = setup();
        bind_and_read(&mut harness, &scope, &cancel).await;
        let mut approval = Allow;

        let mut grounder = UnavailableGrounder;
        for (id, args) in [
            ("display", json!({"display_id":1})),
            ("cursor", json!({"shows_cursor":true})),
        ] {
            assert!(
                !harness
                    .execute(
                        &scope,
                        &call(id),
                        "computer_v2_capture",
                        args,
                        &cancel,
                        &mut approval,
                        &mut grounder
                    )
                    .await
                    .success
            );
        }
        assert!(state.borrow().captures.is_empty());
        assert!(
            harness
                .execute(
                    &scope,
                    &call("window-capture"),
                    "computer_v2_capture",
                    json!({}),
                    &cancel,
                    &mut approval,
                    &mut grounder
                )
                .await
                .success
        );
        assert_eq!(state.borrow().captures, vec![None]);
        assert!(!harness.capture.as_ref().unwrap().actionable);
    }
    #[tokio::test(flavor = "current_thread")]
    async fn background_combined_capture_exposes_correlated_ax_without_pointer_authority() {
        let (mut harness, _, scope, cancel) = setup();
        bind_and_read(&mut harness, &scope, &cancel).await;
        let output = harness
            .execute(
                &scope,
                &call("combined"),
                "computer_v2_capture",
                json!({"include_accessibility":true}),
                &cancel,
                &mut Allow,
                &mut UnavailableGrounder,
            )
            .await;
        assert!(output.success);
        let image = harness.capture.as_ref().unwrap();
        assert!(!image.actionable);
        assert!(output.content.iter().any(|item| matches!(item,
            ContentItem::Text{text} if text.starts_with(&format!("SYNCHRONIZED_AX observation_id={}\n",image.id)))));
        assert!(
            output
                .content
                .iter()
                .any(|item| matches!(item, ContentItem::Image { .. }))
        );
        assert!(harness.publication.is_some());
        assert!(
            !output.content.iter().any(
                |item| matches!(item, ContentItem::Text{text} if text.contains(" capture_id="))
            )
        );
    }
    #[tokio::test(flavor = "current_thread")]
    async fn post_action_image_is_observation_only_and_keeps_operation_unresolved() {
        let (_, state, mut scope, cancel) = setup();
        scope.policy = InteractionPolicy::Foreground;
        let mut harness = Harness::new(FakeBackend(state.clone()), scope.policy);
        harness.begin_turn(scope.clone()).unwrap();
        let output = harness
            .execute(
                &scope,
                &call("foreground"),
                "computer_v2_open",
                json!({"bundle_id":"test.app","activation":"foreground"}),
                &cancel,
                &mut Allow,
                &mut UnavailableGrounder,
            )
            .await;
        assert!(output.success);
        let output = harness
            .execute(
                &scope,
                &call("one-input"),
                "computer_v2_type",
                json!({"text":"new"}),
                &cancel,
                &mut Allow,
                &mut UnavailableGrounder,
            )
            .await;
        assert!(!output.success);
        assert_eq!(state.borrow().inputs, 1);
        assert_eq!(harness.outcome_counts(), (1, 0));
        assert!(harness.capture.is_none());
        assert!(
            output
                .content
                .iter()
                .any(|item| matches!(item, ContentItem::Image { .. }))
        );
        assert!(output.content.iter().any(|item| matches!(item,ContentItem::Text{text} if text.starts_with("POST_ACTION_CAPTURE observation_id=") && text.contains("actionable=false") && !text.contains("capture_id="))));
    }
    #[tokio::test(flavor = "current_thread")]
    async fn unplanned_input_is_not_replayed_and_changed_exact_property_can_reconcile_receipt() {
        let (_, state, mut scope, cancel) = setup();
        let mut harness = Harness::new(FakeBackend(state.clone()), InteractionPolicy::Foreground);
        scope.policy = InteractionPolicy::Foreground;
        harness.begin_turn(scope.clone()).unwrap();
        harness.set_browser_model(true);
        let mut approval = Allow;

        let mut grounder = UnavailableGrounder;
        assert!(
            harness
                .execute(
                    &scope,
                    &call("foreground-bind"),
                    "computer_v2_open",
                    json!({"bundle_id":"test.app","activation":"foreground"}),
                    &cancel,
                    &mut approval,
                    &mut grounder
                )
                .await
                .success
        );
        assert!(
            harness
                .execute(
                    &scope,
                    &call("baseline"),
                    "computer_v2_snapshot",
                    json!({}),
                    &cancel,
                    &mut approval,
                    &mut grounder
                )
                .await
                .success
        );
        assert!(
            !harness
                .execute(
                    &scope,
                    &call("type"),
                    "computer_v2_type",
                    json!({"text":"new"}),
                    &cancel,
                    &mut approval,
                    &mut grounder
                )
                .await
                .success
        );
        assert_eq!(state.borrow().inputs, 1);
        let operation = *harness.operations.keys().next().unwrap();
        assert_eq!(harness.outcome_counts(), (1, 0));
        assert!(
            !harness
                .execute(
                    &scope,
                    &call("blocked-repeat"),
                    "computer_v2_type",
                    json!({"text":"new"}),
                    &cancel,
                    &mut approval,
                    &mut grounder
                )
                .await
                .success
        );
        assert_eq!(state.borrow().inputs, 1);
        state.borrow_mut().snapshot.elements[0].value = Some("new".into());
        assert!(
            harness
                .execute(
                    &scope,
                    &call("result-read"),
                    "computer_v2_snapshot",
                    json!({}),
                    &cancel,
                    &mut approval,
                    &mut grounder
                )
                .await
                .success
        );
        let snapshot = harness.publication.as_ref().unwrap().snapshot.id;
        let output=harness.execute(&scope,&call("verify-rendered-value"),"computer_v2_verify",json!({"operation_id":operation,"snapshot_id":snapshot,"element_index":0,"property":"value","expected":"new"}),&cancel,&mut approval,&mut grounder).await;
        assert!(output.success);
        assert_eq!(harness.outcome_counts(), (0, 0));
        assert_eq!(state.borrow().inputs, 1);
        assert!(state.borrow().captures.is_empty());
    }
    async fn bind_and_read(
        h: &mut Harness<FakeBackend>,
        scope: &ExecutionScope,
        cancel: &CancellationToken,
    ) {
        let mut gate = Allow;

        let mut vision = UnavailableGrounder;
        assert!(
            h.execute(
                scope,
                &call("bind"),
                "computer_v2_open",
                json!({"bundle_id":"test.app"}),
                cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
        assert!(
            h.execute(
                scope,
                &call("read"),
                "computer_v2_read_page",
                json!({}),
                cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
    }
    fn fill_args(h: &Harness<FakeBackend>) -> Value {
        let (token, _) = h
            .publication
            .as_ref()
            .unwrap()
            .references
            .iter()
            .find(|(_, r)| r.capability == ReferenceCapability::Field)
            .unwrap();
        json!({"field_ref":token,"text":"new"})
    }
    #[tokio::test(flavor = "current_thread")]
    async fn status_does_not_prompt_and_background_global_tools_never_send_input() {
        let (mut h, state, scope, cancel) = setup();
        let mut gate = Allow;

        let mut vision = UnavailableGrounder;
        assert!(
            h.execute(
                &scope,
                &call("status"),
                "computer_v2_status",
                json!({}),
                &cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
        let result = h
            .execute(
                &scope,
                &call("key"),
                "computer_v2_keypress",
                json!({"key":"return"}),
                &cancel,
                &mut gate,
                &mut vision,
            )
            .await;
        assert!(!result.success);
        assert_eq!(state.borrow().inputs, 0);
        assert_eq!(state.borrow().prompts, 0);
    }
    #[tokio::test(flavor = "current_thread")]
    async fn native_fill_verifies_exact_value_and_duplicate_call_cannot_replay_input() {
        let (mut h, state, scope, cancel) = setup();
        bind_and_read(&mut h, &scope, &cancel).await;
        let args = fill_args(&h);
        let mut gate = Allow;

        let mut vision = UnavailableGrounder;
        assert!(
            h.execute(
                &scope,
                &call("fill"),
                "computer_v2_fill",
                args.clone(),
                &cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
        assert_eq!(state.borrow().mutations, 1);
        assert_eq!(h.outcome_counts(), (0, 0));
        assert!(
            !h.execute(
                &scope,
                &call("fill"),
                "computer_v2_fill",
                args,
                &cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
        assert_eq!(state.borrow().mutations, 1);
    }
    #[tokio::test(flavor = "current_thread")]
    async fn cancellation_while_native_approval_is_pending_prevents_any_mutation() {
        let (mut h, state, scope, cancel) = setup();
        bind_and_read(&mut h, &scope, &cancel).await;
        let args = fill_args(&h);
        let mut gate = CancelApproval(cancel.clone());

        let mut vision = UnavailableGrounder;
        assert!(
            !h.execute(
                &scope,
                &call("fill"),
                "computer_v2_fill",
                args,
                &cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
        assert_eq!(state.borrow().mutations, 0);
        assert_eq!(h.outcome_counts(), (0, 0));
    }
    #[tokio::test(flavor = "current_thread")]
    async fn approval_does_not_authorize_replaced_baseline() {
        let (mut h, state, scope, cancel) = setup();
        bind_and_read(&mut h, &scope, &cancel).await;
        let args = fill_args(&h);
        let mut gate = ChangeApproval(state.clone());

        let mut vision = UnavailableGrounder;
        assert!(
            !h.execute(
                &scope,
                &call("fill"),
                "computer_v2_fill",
                args,
                &cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
        assert_eq!(state.borrow().mutations, 0);
    }
    #[tokio::test(flavor = "current_thread")]
    async fn errors_before_final_native_boundary_are_not_uncertain_dispatch() {
        let (mut h, state, scope, cancel) = setup();
        bind_and_read(&mut h, &scope, &cancel).await;
        state.borrow_mut().behavior = MutationBehavior::RejectBeforeDispatch;
        let args = fill_args(&h);
        let mut gate = Allow;

        let mut vision = UnavailableGrounder;
        assert!(
            !h.execute(
                &scope,
                &call("fill"),
                "computer_v2_fill",
                args,
                &cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
        assert_eq!(state.borrow().mutations, 0);
        assert!(
            h.operations
                .values()
                .all(|r| r.dispatch == DispatchState::NotDispatched)
        );
        assert_eq!(h.outcome_counts(), (0, 0));
    }
    #[tokio::test(flavor = "current_thread")]
    async fn lost_acknowledgement_only_allows_read_only_original_plan_recovery() {
        let (mut h, state, scope, cancel) = setup();
        bind_and_read(&mut h, &scope, &cancel).await;
        state.borrow_mut().behavior = MutationBehavior::LostAcknowledgement;
        let args = fill_args(&h);
        let mut gate = Allow;

        let mut vision = UnavailableGrounder;
        assert!(
            !h.execute(
                &scope,
                &call("fill"),
                "computer_v2_fill",
                args,
                &cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
        assert_eq!(h.outcome_counts(), (1, 1));
        let id = *h.operations.keys().next().unwrap();
        let replaced = h
            .execute(
                &scope,
                &call("badverify"),
                "computer_v2_verify",
                json!({"operation_id":id,"expected":"guessed"}),
                &cancel,
                &mut gate,
                &mut vision,
            )
            .await;
        assert!(!replaced.success);
        let recovered = h
            .execute(
                &scope,
                &call("verify"),
                "computer_v2_verify",
                json!({"operation_id":id}),
                &cancel,
                &mut gate,
                &mut vision,
            )
            .await;
        assert!(recovered.success);
        assert_eq!(state.borrow().mutations, 1);
        assert_eq!(h.outcome_counts(), (0, 0));
    }
    #[tokio::test(flavor = "current_thread")]
    async fn revoked_scope_and_unexposed_tokens_cannot_act() {
        let (mut h, state, scope, cancel) = setup();
        bind_and_read(&mut h, &scope, &cancel).await;
        let mut gate = Allow;

        let mut vision = UnavailableGrounder;
        assert!(
            !h.execute(
                &scope,
                &call("missing"),
                "computer_v2_fill",
                json!({"field_ref":"unpublished","text":"new"}),
                &cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
        let args = fill_args(&h);
        h.authority().revoke();
        assert!(
            !h.execute(
                &scope,
                &call("revoked"),
                "computer_v2_fill",
                args,
                &cancel,
                &mut gate,
                &mut vision
            )
            .await
            .success
        );
        assert_eq!(state.borrow().mutations, 0);
    }
    #[test]
    fn grounding_cannot_claim_unagreed_points_or_skip_cascade() {
        let capture = image(fixtures::snapshot("").window);
        let a = Point { x: 10., y: 10. };
        let b = Point { x: 12., y: 12. };
        let far = Point { x: 90., y: 90. };
        let mut decision = QualifiedGrounding {
            capture_id: capture.id,
            point: Point { x: 11., y: 11. },
            model_points: vec![("goclick-base-4bit".into(), a), ("gui-owl-2b".into(), b)],
            method: GroundingMethod::GoClickGuiOwlAgreement,
        };
        assert!(validate_grounding(&decision, &capture).is_ok());
        decision.point = far;
        assert!(validate_grounding(&decision, &capture).is_err());
        decision.point = Point { x: 11., y: 11. };
        decision.model_points[1].1 = far;
        assert!(validate_grounding(&decision, &capture).is_err());
        decision.method = GroundingMethod::ShowUiDisambiguated;
        decision.model_points.push(("showui-2b-4bit".into(), b));
        assert!(validate_grounding(&decision, &capture).is_ok());
        decision.model_points.remove(0);
        decision.point = Point { x: 51., y: 51. };
        assert!(validate_grounding(&decision, &capture).is_err());
    }
}
