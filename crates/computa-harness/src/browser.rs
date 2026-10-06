//! Background Chrome tools. Model references name exposed observations, never
//! CDP handles. The native connection grant and extension constrain all commands.
use crate::{
    executor::{
        ApprovalGate, BrowserToolLane, DispatchState, HarnessError, LocalFuture, NativeApproval,
        TurnAuthority,
    },
    semantic::{ModelReference, ReadPublication, ReferenceCapability, SemanticReader},
    verification::canonical,
};
use computa_browser::leases::{Attachment, BrowserControl, BrowserOwnership, Candidate};
use computa_contracts::chrome::{PRESS_FUNCTION as PRESS, SET_TEXT_FUNCTION as SET_TEXT};
use computa_contracts::{
    appserver::{ExecutionScope, ToolOutput},
    tools::*,
};
use computa_macos::{AxNode, AxSnapshot, WindowInfo, unix_time};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
struct Document {
    frame: String,
    loader: String,
    url: String,
}
#[derive(Clone)]
struct Observation {
    snapshot: AxSnapshot,
    document: Document,
    backend: HashMap<Uuid, u64>,
    owned: bool,
}
#[derive(Clone)]
struct Inventory {
    items: Vec<(String, Candidate)>,
    next: usize,
    cursor: Uuid,
    page_size: usize,
}
#[derive(Clone)]
struct BrowserPlan {
    kind: PostconditionKind,
    attachment_generation: Uuid,
    owned: bool,
    document: Document,
    action: Uuid,
    backend: u64,
    role: Option<String>,
    label: String,
    action_value: Option<String>,
    region: Option<Uuid>,
    expected: Option<String>,
    baseline: String,
    dialog_baseline: HashSet<Uuid>,
    root: Option<Uuid>,
    already_satisfied: bool,
}
#[derive(Clone)]
struct Receipt {
    id: Uuid,
    dispatch: DispatchState,
    plan: BrowserPlan,
    reads: usize,
    status: &'static str,
    failure: Option<String>,
}

/// One lane per execution scope. The shared controller carries a separately
/// authenticated Chrome generation/bridge epoch; neither is a model argument.
pub struct ChromeBrowserLane {
    controller: Arc<dyn BrowserControl>,
    scope: Option<ExecutionScope>,
    authority: Option<TurnAuthority>,
    attachment: Option<Attachment>,
    attachment_generation: Uuid,
    temporary_task: Option<Uuid>,
    inventory: Option<Inventory>,
    candidates: HashMap<String, Candidate>,
    reader: SemanticReader,
    publication: Option<ReadPublication>,
    observation: Option<Observation>,
    identities: HashMap<String, Uuid>,
    identity_document: Option<Document>,
    receipts: HashMap<Uuid, Receipt>,
    failures: HashMap<String, usize>,
}
impl ChromeBrowserLane {
    pub fn new(controller: Arc<dyn BrowserControl>) -> Self {
        Self {
            controller,
            scope: None,
            authority: None,
            attachment: None,
            attachment_generation: Uuid::new_v4(),
            temporary_task: None,
            inventory: None,
            candidates: HashMap::new(),
            reader: SemanticReader::default(),
            publication: None,
            observation: None,
            identities: HashMap::new(),
            identity_document: None,
            receipts: HashMap::new(),
            failures: HashMap::new(),
        }
    }
    fn check(
        &mut self,
        scope: &ExecutionScope,
        cancel: &CancellationToken,
    ) -> Result<(), HarnessError> {
        if cancel.is_cancelled() {
            return Err(HarnessError::Cancelled);
        }
        if let Some(authority) = &self.authority {
            authority.check()?
        }
        match &self.scope {
            Some(existing) if existing != scope => Err(HarnessError::StaleScope),
            Some(_) => Ok(()),
            None => {
                self.scope = Some(scope.clone());
                Ok(())
            }
        }
    }
    fn attachment(&self) -> Result<&Attachment, HarnessError> {
        self.attachment.as_ref().ok_or(HarnessError::Unbound)
    }
    async fn command(&self, method: &str, params: Value) -> Result<Value, HarnessError> {
        let token = &self.attachment()?.attachment_token;
        self.controller
            .command(token, method, params)
            .await
            .map_err(browser_error)
    }
    async fn document(&self) -> Result<Document, HarnessError> {
        document_from(
            &self.command("Page.getFrameTree", json!({})).await?,
            self.controller.ownership() == BrowserOwnership::Owned,
        )
    }
    fn clear_reads(&mut self) {
        self.reader.invalidate();
        self.publication = None;
        self.observation = None;
    }
    fn emit(&mut self, p: ReadPublication) -> ToolOutput {
        let text = p.text.clone();
        self.publication = Some(p);
        ToolOutput::text(text, true)
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
        let r = p
            .references
            .get(token)
            .ok_or(HarnessError::StaleReference)?;
        if r.snapshot_id != p.snapshot.id
            || !p.exposed.contains(&r.index)
            || capability.is_some_and(|c| c != r.capability)
        {
            return Err(HarnessError::StaleReference);
        }
        Ok(r.clone())
    }
    fn current(&self, id: &str, index: usize) -> Result<&Observation, HarnessError> {
        let p = self
            .publication
            .as_ref()
            .ok_or(HarnessError::StaleReference)?;
        let o = self
            .observation
            .as_ref()
            .ok_or(HarnessError::StaleReference)?;
        if parse_uuid(id)? != p.snapshot.id
            || o.snapshot.id != p.snapshot.id
            || !p.exposed.contains(&index)
        {
            return Err(HarnessError::StaleReference);
        }
        Ok(o)
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
            ToolCall::Follow(args) => {
                let r = self.reference(&args.link_ref, Some(ReferenceCapability::Link))?;
                ToolCall::FollowLink(ElementArgs {
                    snapshot_id: r.snapshot_id.to_string(),
                    element_index: r.index,
                })
            }
            ToolCall::Press(args) => {
                let r = self.reference(&args.action_ref, None)?;
                if r.capability != ReferenceCapability::Action("AXPress".into()) {
                    return Err(HarnessError::StaleReference);
                }
                let postcondition = args
                    .postcondition
                    .map(|p| -> Result<_, HarnessError> {
                        Ok(Postcondition {
                            kind: p.kind,
                            expected: p.expected,
                            element_index: p
                                .region_ref
                                .map(|token| {
                                    self.reference(&token, Some(ReferenceCapability::Region))
                                        .map(|r| r.index)
                                })
                                .transpose()?,
                            detail_element_index: p
                                .detail_ref
                                .map(|token| {
                                    self.reference(&token, Some(ReferenceCapability::Region))
                                        .map(|r| r.index)
                                })
                                .transpose()?,
                        })
                    })
                    .transpose()?;
                ToolCall::Ax(ActionArgs {
                    snapshot_id: r.snapshot_id.to_string(),
                    element_index: r.index,
                    ax_action: AxAction::Press,
                    postcondition,
                })
            }
            other => other,
        })
    }
    async fn observe(
        &mut self,
        scope: &ExecutionScope,
        cancel: &CancellationToken,
    ) -> Result<Observation, HarnessError> {
        self.check(scope, cancel)?;
        let before = self.document().await?;
        self.check(scope, cancel)?;
        self.command("Accessibility.enable", json!({})).await?;
        let tree = self
            .command("Accessibility.getFullAXTree", json!({"depth":64}))
            .await?;
        self.check(scope, cancel)?;
        let dom = self
            .command(
                "DOMSnapshot.captureSnapshot",
                json!({"computedStyles":["cursor","visibility","display","pointer-events"]}),
            )
            .await?;
        self.check(scope, cancel)?;
        let after = self.document().await?;
        if before != after {
            return Err(HarnessError::Browser("The Chrome document changed during the read. Read again; no reference was published.".into()));
        }
        if self.identity_document.as_ref() != Some(&before) {
            self.identities.clear();
            self.identity_document = Some(before.clone());
        }
        let observation = project_observation(
            &tree,
            &dom,
            before,
            self.attachment_generation,
            &mut self.identities,
            self.controller.ownership() == BrowserOwnership::Owned,
        )?;
        self.check(scope, cancel)?;
        Ok(observation)
    }
    async fn tabs(
        &mut self,
        args: TabsArgs,
        scope: &ExecutionScope,
        cancel: &CancellationToken,
    ) -> Result<ToolOutput, HarnessError> {
        if args.page_size.is_some_and(|n| !(1..=100).contains(&n)) {
            return Err(HarnessError::Invalid("page_size".into()));
        }
        if let Some(raw) = args.cursor {
            let id = parse_uuid(&raw)?;
            let page = self
                .inventory
                .as_ref()
                .ok_or(HarnessError::StaleReference)?;
            if page.cursor != id || args.page_size.is_some_and(|n| n != page.page_size) {
                return Err(HarnessError::StaleReference);
            }
        } else {
            let items = self.controller.inventory().await.map_err(browser_error)?;
            self.check(scope, cancel)?;
            self.candidates.clear();
            let items = items
                .into_iter()
                .map(|candidate| {
                    let token = format!("tab_{}", Uuid::new_v4().simple());
                    (token, candidate)
                })
                .collect();
            self.inventory = Some(Inventory {
                items,
                next: 0,
                cursor: Uuid::new_v4(),
                page_size: args.page_size.unwrap_or(25),
            });
        }
        let page = self
            .inventory
            .as_mut()
            .ok_or(HarnessError::StaleReference)?;
        let start = page.next;
        let lines = publish_inventory_page(page, &mut self.candidates)?;
        let end = page.next;
        let more = end < page.items.len();
        let cursor = more.then(|| {
            page.cursor = Uuid::new_v4();
            page.cursor
        });
        let text = format!(
            "BROWSER_TABS total={} returned={} inventory_generation={} bridge_epoch={}{}\n{}Exhaust next_cursor before claiming a tab is absent. Candidate tokens identify this captured inventory; binding revalidates the exact target and URL.",
            page.items.len(),
            end - start,
            self.controller.generation(),
            self.controller.bridge_epoch(),
            cursor
                .map(|c| format!(" next_cursor={c}"))
                .unwrap_or_default(),
            lines
        );
        if !more {
            self.inventory = None
        }
        Ok(ToolOutput::text(text, true))
    }
    async fn bind(
        &mut self,
        args: CandidateArgs,
        temporary: bool,
        scope: &ExecutionScope,
        cancel: &CancellationToken,
        gate: &mut dyn ApprovalGate,
    ) -> Result<ToolOutput, HarnessError> {
        let candidate = self
            .candidates
            .get(&args.candidate_token)
            .cloned()
            .ok_or(HarnessError::StaleReference)?;
        if candidate.availability != "available" {
            return Err(HarnessError::Browser(
                "The observed Chrome candidate is not available.".into(),
            ));
        }
        let inventory = self.controller.inventory().await.map_err(browser_error)?;
        self.check(scope, cancel)?;
        if !inventory.iter().any(|current| {
            current.target_id == candidate.target_id
                && current.url == candidate.url
                && current.availability == "available"
        }) {
            return Err(HarnessError::StaleReference);
        }
        if self.temporary_task.is_some() {
            return Err(HarnessError::Browser("This turn already owns a temporary workspace. End it before binding another tab; cleanup ownership was preserved.".into()));
        }
        if temporary && self.attachment.is_some() {
            return Err(HarnessError::Browser("Create a temporary workspace before binding the observed source tab; no existing attachment was changed.".into()));
        }
        if let Some(previous) = self.attachment.as_ref().cloned() {
            self.controller
                .detach(&previous.attachment_token)
                .await
                .map_err(browser_error)?;
            self.attachment = None;
            self.clear_reads();
        }
        let (target, expected) = if temporary {
            self.approve(scope,"Create temporary browser workspace",format!("Source: {}\nURL: {}\nCreate one inactive temporary tab; only its exact lease may be closed.",candidate.title,candidate.url),cancel,gate).await?;
            let fresh = self.controller.inventory().await.map_err(browser_error)?;
            self.check(scope, cancel)?;
            if !fresh.iter().any(|c| {
                c.target_id == candidate.target_id
                    && c.url == candidate.url
                    && c.availability == "available"
            }) {
                return Err(HarnessError::StaleReference);
            }
            let nonce = Uuid::new_v4();
            self.temporary_task = Some(nonce);
            let result = self
                .controller
                .create_temporary(nonce, &candidate.target_id, &candidate.url)
                .await
                .map_err(browser_error)?;
            self.check(scope, cancel)?;
            let target = result["targetID"]
                .as_str()
                .ok_or(HarnessError::StaleReference)?
                .to_owned();
            let url = result["url"]
                .as_str()
                .ok_or(HarnessError::StaleReference)?
                .to_owned();
            if url != candidate.url {
                return Err(HarnessError::Browser("The temporary workspace did not preserve the observed source URL; its exact lease remains tracked for cleanup.".into()));
            }
            (target, url)
        } else {
            (candidate.target_id, candidate.url)
        };
        self.check(scope, cancel)?;
        let attachment = self
            .controller
            .attach(&target)
            .await
            .map_err(browser_error)?;
        self.attachment = Some(attachment.clone());
        if attachment.url != expected {
            if self
                .controller
                .detach(&attachment.attachment_token)
                .await
                .is_ok()
            {
                self.attachment = None;
            }
            return Err(HarnessError::StaleReference);
        }
        self.attachment_generation = Uuid::new_v4();
        self.clear_reads();
        self.identities.clear();
        self.identity_document = None;
        self.check(scope, cancel)?;
        Ok(ToolOutput::text(
            format!(
                "BOUND_BROWSER_TAB title={} url={} mode={}\nNo activation, global input, navigation fallback or screenshot authority was granted. Read before acting.",
                json!(attachment.title),
                json!(attachment.url),
                if temporary {
                    "temporary_workspace"
                } else {
                    "existing"
                }
            ),
            true,
        ))
    }
    async fn approve(
        &mut self,
        scope: &ExecutionScope,
        title: &str,
        details: String,
        cancel: &CancellationToken,
        gate: &mut dyn ApprovalGate,
    ) -> Result<(), HarnessError> {
        self.check(scope, cancel)?;
        let request = NativeApproval {
            id: format!("browser:{}:{}", scope.generation, Uuid::new_v4()),
            task_id: scope.task_id.clone(),
            title: title.into(),
            summary: details.clone(),
            details,
        };
        let approved = tokio::select! {_ = cancel.cancelled()=>return Err(HarnessError::Cancelled),result=gate.approve(request)=>result?};
        self.check(scope, cancel)?;
        if approved {
            Ok(())
        } else {
            Err(HarnessError::Declined)
        }
    }
    async fn read(
        &mut self,
        mut args: ReadArgs,
        scope: &ExecutionScope,
        cancel: &CancellationToken,
    ) -> Result<ToolOutput, HarnessError> {
        default_browser_view(&mut args);
        if let Some(cursor) = &args.cursor {
            let p = self.reader.continue_read(
                parse_uuid(cursor)?,
                Some(&args),
                self.attachment_generation,
                16_384,
            )?;
            self.check(scope, cancel)?;
            return Ok(self.emit(p));
        }
        let observation = if let (Some(id), Some(index)) = (&args.snapshot_id, args.element_index) {
            self.current(id, index)?.clone()
        } else {
            self.observe(scope, cancel).await?
        };
        let exposed = self.publication.as_ref().map(|p| p.exposed.clone());
        let publication = self.reader.start_browser(
            observation.snapshot.clone(),
            args,
            exposed.as_ref(),
            16_384,
        )?;
        self.observation = Some(observation);
        Ok(self.emit(publication))
    }
    // Keep observation, native approval and cancellation authority explicit at
    // the one browser input boundary rather than hiding them in model arguments.
    #[allow(clippy::too_many_arguments)]
    async fn mutate(
        &mut self,
        id: &str,
        index: usize,
        text: Option<String>,
        postcondition: Option<Postcondition>,
        follow: bool,
        scope: &ExecutionScope,
        cancel: &CancellationToken,
        gate: &mut dyn ApprovalGate,
    ) -> Result<ToolOutput, HarnessError> {
        if self
            .receipts
            .values()
            .any(|receipt| receipt.status == "verification_pending")
        {
            return Err(HarnessError::PendingOutcome);
        }
        if text
            .as_ref()
            .is_some_and(|s| s.len() > 4096 || s.chars().any(|c| c == '\0'))
        {
            return Err(HarnessError::Invalid("text".into()));
        }
        let observation = self.current(id, index)?.clone();
        let exposed = self.publication.as_ref().unwrap().exposed.clone();
        let plan = BrowserPlan::compile(
            &observation,
            index,
            &exposed,
            text.as_deref(),
            postcondition.as_ref(),
            follow,
        )?;
        let key = format!(
            "{}:{}:{}",
            self.attachment_generation,
            plan.backend,
            text.as_deref().unwrap_or("AXPress")
        );
        if self.failures.get(&key).copied().unwrap_or(0) >= 3 || self.receipts.len() >= 64 {
            return Err(HarnessError::RecoveryExhausted);
        }
        let operation = Uuid::new_v4();
        let receipt = Receipt {
            id: operation,
            dispatch: DispatchState::NotDispatched,
            plan: plan.clone(),
            reads: 0,
            status: if plan.already_satisfied {
                "already_satisfied"
            } else {
                "pending"
            },
            failure: None,
        };
        self.receipts.insert(operation, receipt);
        if plan.already_satisfied {
            return Ok(ToolOutput::text(
                format!(
                    "ALREADY_SATISFIED operation_id={operation} dispatch=not_dispatched\nOnly the declared property is established; no input occurred."
                ),
                true,
            ));
        }
        if let Err(error) = self
            .approve(
                scope,
                "Browser action",
                format!(
                    "Document: {}\nTarget: {}\nAction: {}\nExpected property: {:?} {}",
                    plan.document.url,
                    plan.label,
                    if text.is_some() {
                        "set text without submission"
                    } else {
                        "press once"
                    },
                    plan.kind,
                    json!(plan.expected)
                ),
                cancel,
                gate,
            )
            .await
        {
            self.receipts.get_mut(&operation).unwrap().status = "rejected_before_dispatch";
            return Err(error);
        }
        let fresh = self.observe(scope, cancel).await?;
        plan.revalidate(&fresh)?;
        self.check(scope, cancel)?;
        let world = self
            .command(
                "Page.createIsolatedWorld",
                json!({"frameId":fresh.document.frame,"worldName":"LocalCodexBrowserBroker"}),
            )
            .await?;
        let context = world["executionContextId"]
            .as_u64()
            .filter(|n| *n > 0)
            .ok_or(HarnessError::StaleReference)?;
        self.check(scope, cancel)?;
        let group = format!("heydash-mutation-{operation}");
        let resolved=self.command("DOM.resolveNode",json!({"backendNodeId":plan.backend,"executionContextId":context,"objectGroup":group})).await?;
        let object = resolved["object"]["objectId"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or(HarnessError::StaleReference)?
            .to_owned();
        let before_dispatch = self.document().await?;
        if before_dispatch != plan.document {
            let _ = self
                .command("Runtime.releaseObjectGroup", json!({"objectGroup":group}))
                .await;
            return Err(HarnessError::StaleReference);
        }
        self.check(scope, cancel)?;
        self.clear_reads();
        // Once handed to Chrome this mutation is never replayed, including when
        // cancellation interrupts the response. The group is released separately.
        self.receipts.get_mut(&operation).unwrap().dispatch = DispatchState::DeliveryUncertain;
        self.receipts.get_mut(&operation).unwrap().status = "verification_pending";
        let args = if let Some(value) = &text {
            json!([{"value":plan.document.url},{"value":value}])
        } else {
            json!([{"value":plan.document.url}])
        };
        let result = tokio::select! {_ = cancel.cancelled()=>Err(HarnessError::Cancelled),result=self.command("Runtime.callFunctionOn",json!({"objectId":object,"functionDeclaration":if text.is_some(){SET_TEXT}else{PRESS},"arguments":args,"returnByValue":true,"awaitPromise":true,"userGesture":true}))=>result};
        let release = self
            .command("Runtime.releaseObjectGroup", json!({"objectGroup":group}))
            .await;
        if let Err(error) = release {
            self.receipts.get_mut(&operation).unwrap().failure =
                Some(format!("Object group cleanup failed: {error}"));
        }
        match result {
            Ok(value)
                if value["result"]["value"] == true && value.get("exceptionDetails").is_none() =>
            {
                self.receipts.get_mut(&operation).unwrap().dispatch = DispatchState::Dispatched
            }
            Ok(value)
                if value["result"]["value"] == false && value.get("exceptionDetails").is_none() =>
            {
                self.receipts.get_mut(&operation).unwrap().dispatch = DispatchState::NotDispatched;
                self.receipts.get_mut(&operation).unwrap().status = "rejected_before_dispatch";
                return Ok(ToolOutput::text(
                    format!(
                        "ACTION_EVIDENCE operation_id={operation} dispatch=not_dispatched\nThe current DOM element rejected the safe operation; no fallback was attempted."
                    ),
                    false,
                ));
            }
            Err(error) => {
                self.receipts.get_mut(&operation).unwrap().failure = Some(error.to_string());
                *self.failures.entry(key).or_default() += 1;
                return Ok(receipt_output(self.receipts.get(&operation).unwrap()));
            }
            _ => {
                self.receipts.get_mut(&operation).unwrap().failure =
                    Some("Chrome returned no exact boolean mutation receipt.".into());
                *self.failures.entry(key).or_default() += 1;
                return Ok(receipt_output(self.receipts.get(&operation).unwrap()));
            }
        }
        self.check(scope, cancel)?;
        for _ in 0..3 {
            let fresh = self.observe(scope, cancel).await?;
            self.receipts.get_mut(&operation).unwrap().reads += 1;
            if plan.evaluate(&fresh).is_ok() {
                self.receipts.get_mut(&operation).unwrap().status = "verified";
                self.failures.remove(&key);
                let p = self.reader.start_browser(
                    fresh.snapshot.clone(),
                    ReadArgs {
                        view: Some(ReadView::Overview),
                        ..Default::default()
                    },
                    None,
                    16_384,
                )?;
                self.observation = Some(fresh);
                let read = self.emit(p);
                let mut output = receipt_output(self.receipts.get(&operation).unwrap());
                output.content.extend(read.content);
                return Ok(output);
            }
            tokio::select! {_ = cancel.cancelled()=>return Err(HarnessError::Cancelled),_ = tokio::time::sleep(std::time::Duration::from_millis(120))=>{}}
        }
        *self.failures.entry(key).or_default() += 1;
        Ok(receipt_output(self.receipts.get(&operation).unwrap()))
    }
    async fn verify(
        &mut self,
        args: VerifyArgs,
        scope: &ExecutionScope,
        cancel: &CancellationToken,
    ) -> Result<ToolOutput, HarnessError> {
        if args.snapshot_id.is_some() || args.element_index.is_some() || args.property.is_some() {
            return Err(HarnessError::Invalid("Verification retains its original host-owned plan; only operation_id and matching expected are accepted.".into()));
        }
        let id = parse_uuid(&args.operation_id)?;
        let receipt = self
            .receipts
            .get(&id)
            .cloned()
            .ok_or(HarnessError::StaleReference)?;
        if args
            .expected
            .as_ref()
            .is_some_and(|expected| Some(expected) != receipt.plan.expected.as_ref())
        {
            return Err(HarnessError::Invalid(
                "Verification expected value cannot replace the retained plan.".into(),
            ));
        }
        if receipt.status != "verification_pending" {
            return Ok(ToolOutput::text(
                format!(
                    "HISTORICAL_ACTION_STATUS operation_id={} dispatch={} status={} property={} expected={}\nThis is the retained outcome of an earlier observation. No fresh page read was performed and no current property or whole-task completion is established.",
                    receipt.id,
                    json!(receipt.dispatch),
                    receipt.status,
                    json!(receipt.plan.kind),
                    json!(receipt.plan.expected)
                ),
                true,
            ));
        }
        if receipt.reads >= 5 {
            return Err(HarnessError::RecoveryExhausted);
        }
        let observation = self.observe(scope, cancel).await?;
        let receipt = self.receipts.get_mut(&id).unwrap();
        receipt.reads += 1;
        if receipt.plan.evaluate(&observation).is_ok() {
            receipt.status = "verified"
        }
        Ok(receipt_output(receipt))
    }
    async fn execute_inner(
        &mut self,
        scope: &ExecutionScope,
        name: &str,
        args: Value,
        gate: &mut dyn ApprovalGate,
        cancel: &CancellationToken,
    ) -> Result<ToolOutput, HarnessError> {
        self.check(scope, cancel)?;
        let call = self.canonicalize(parse_tool(name, args)?)?;
        match call{
        ToolCall::Tabs(args)=>self.tabs(args,scope,cancel).await,ToolCall::BindTab(args)=>self.bind(args,false,scope,cancel,gate).await,ToolCall::CreateWorkspace(args)=>self.bind(args,true,scope,cancel,gate).await,
        ToolCall::Snapshot(args)=>self.read(args,scope,cancel).await,
        ToolCall::Continue(args)=>{let cursor=parse_uuid(&args.cursor)?;if self.inventory.as_ref().is_some_and(|i|i.cursor==cursor){return self.tabs(TabsArgs{cursor:Some(args.cursor),page_size:None},scope,cancel).await}let publication=self.reader.continue_read(cursor,None,self.attachment_generation,16_384)?;self.check(scope,cancel)?;Ok(self.emit(publication))},
        ToolCall::Ax(args)=>{if args.ax_action!=AxAction::Press{return Err(HarnessError::Capability("Borrowed Chrome supports observed safe presses and field setters only.".into()))}self.mutate(&args.snapshot_id,args.element_index,None,args.postcondition,false,scope,cancel,gate).await},
        ToolCall::SetText(args)=>self.mutate(&args.snapshot_id,args.element_index,Some(args.text),None,false,scope,cancel,gate).await,
        ToolCall::FollowLink(args)=>self.mutate(&args.snapshot_id,args.element_index,None,None,true,scope,cancel,gate).await,
        ToolCall::Verify(args)=>self.verify(args,scope,cancel).await,
        _=>Err(HarnessError::Capability("The borrowed browser lane has no global input, capture, arbitrary evaluation or foreground fallback.".into()))}
    }
}
impl BrowserToolLane for ChromeBrowserLane {
    fn set_turn_authority(&mut self, authority: TurnAuthority) {
        self.authority = Some(authority)
    }
    fn is_borrowed(&self) -> bool {
        self.controller.ownership() == BrowserOwnership::Borrowed
    }
    fn outcome_counts(&self) -> (u64, u64) {
        let unresolved = self
            .receipts
            .values()
            .filter(|r| r.status == "verification_pending")
            .count() as u64;
        let failed = self
            .receipts
            .values()
            .filter(|r| r.status == "verification_pending" && r.failure.is_some())
            .count() as u64;
        (unresolved, failed)
    }
    fn operation_count(&self) -> usize {
        self.receipts.len()
    }
    fn execute<'a>(
        &'a mut self,
        scope: &'a ExecutionScope,
        name: &'a str,
        args: Value,
        approval: &'a mut dyn ApprovalGate,
        cancellation: &'a CancellationToken,
    ) -> LocalFuture<'a, Result<ToolOutput, HarnessError>> {
        Box::pin(async move {
            self.execute_inner(scope, name, args, approval, cancellation)
                .await
        })
    }
    fn end_turn<'a>(&'a mut self, scope: &'a ExecutionScope) -> LocalFuture<'a, Vec<String>> {
        Box::pin(async move {
            if self.scope.as_ref().is_some_and(|s| s != scope) {
                return vec![
                    "Browser cleanup scope does not match; no foreign tab was closed.".into(),
                ];
            }
            let mut issues = vec![];
            if self
                .receipts
                .values()
                .any(|r| r.status == "verification_pending")
            {
                issues.push("One or more browser actions remain unverified; the turn does not establish completion.".into())
            }
            if let Some(attachment) = self.attachment.as_ref().cloned() {
                match self.controller.detach(&attachment.attachment_token).await {
                    Ok(())=>self.attachment=None,
                    Err(error)=>issues.push(format!("Chrome attachment cleanup failed; exact attachment remains tracked: {error}")),
                }
            }
            if let Some(nonce) = self.temporary_task.take() {
                match self.controller.release_temporary(nonce).await {
                    Ok(receipt) if receipt["closed"] == true => {}
                    Ok(receipt) => {
                        self.temporary_task = Some(nonce);
                        issues.push(format!(
                            "Temporary browser workspace cleanup was not confirmed: {}",
                            receipt
                        ))
                    }
                    Err(error) => {
                        self.temporary_task = Some(nonce);
                        issues.push(format!("Temporary browser workspace cleanup failed; exact lease remains tracked: {error}"))
                    }
                }
            }
            self.clear_reads();
            self.candidates.clear();
            self.inventory = None;
            issues
        })
    }
}
fn default_browser_view(args: &mut ReadArgs) {
    if args.view.is_none() && args.cursor.is_none() {
        args.view = Some(
            if args.query.is_none() && args.snapshot_id.is_none() && args.element_index.is_none() {
                ReadView::Overview
            } else {
                ReadView::All
            },
        );
    }
}
fn publish_inventory_page(
    page: &mut Inventory,
    published: &mut HashMap<String, Candidate>,
) -> Result<String, HarnessError> {
    let requested_end = (page.next + page.page_size).min(page.items.len());
    let mut output = String::new();
    let mut end = page.next;
    for (token, candidate) in &page.items[page.next..requested_end] {
        let (title, tt) = bounded(&candidate.title, 256);
        let (url, ut) = bounded(&candidate.url, 2048);
        let line = format!(
            "{}\n",
            json!({"candidate_token":token,"title":title,"url":url,"availability":candidate.availability,"display_truncated":tt||ut})
        );
        if output.len() + line.len() > 12_288 {
            break;
        }
        output.push_str(&line);
        published.insert(token.clone(), candidate.clone());
        end += 1;
    }
    if end == page.next && page.next < page.items.len() {
        return Err(HarnessError::Invalid(
            "Chrome inventory record exceeded its bounded output budget".into(),
        ));
    }
    page.next = end;
    Ok(output)
}
fn browser_error(error: impl std::fmt::Display) -> HarnessError {
    HarnessError::Browser(format!("Chrome bridge: {error}"))
}
fn parse_uuid(s: &str) -> Result<Uuid, HarnessError> {
    if s.len() > 256 {
        return Err(HarnessError::StaleReference);
    }
    Uuid::parse_str(s).map_err(|_| HarnessError::StaleReference)
}
fn eligible(s: &str) -> bool {
    url::Url::parse(s)
        .is_ok_and(|u| matches!(u.scheme(), "http" | "https") && u.host_str().is_some())
}
fn eligible_url(s: &str, owned: bool) -> bool {
    if owned {
        computa_contracts::chrome::policy::eligible_owned(s)
    } else {
        eligible(s)
    }
}
fn document_from(value: &Value, owned: bool) -> Result<Document, HarnessError> {
    let frame = &value["frameTree"]["frame"];
    let id = frame["id"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or(HarnessError::StaleReference)?;
    let loader = frame["loaderId"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or(HarnessError::StaleReference)?;
    let url = frame["url"]
        .as_str()
        .filter(|s| eligible_url(s, owned) && s.len() <= 16_384)
        .ok_or(HarnessError::StaleReference)?;
    Ok(Document {
        frame: id.into(),
        loader: loader.into(),
        url: url.into(),
    })
}
fn bounded(text: &str, limit: usize) -> (String, bool) {
    if text.len() <= limit {
        return (text.into(), false);
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1
    }
    (text[..end].into(), true)
}
fn ax_value<'a>(node: &'a Value, key: &str) -> Option<&'a Value> {
    node.get(key)?.get("value")
}
fn property<'a>(node: &'a Value, name: &str) -> Option<&'a Value> {
    node.get("properties")?
        .as_array()?
        .iter()
        .find(|p| p["name"] == name)?
        .get("value")?
        .get("value")
}
fn id_set(value: &Value) -> Result<HashSet<u64>, HarnessError> {
    let list = value.as_array().ok_or(HarnessError::StaleReference)?;
    if list.len() > 12_000 {
        return Err(HarnessError::StaleReference);
    }
    let mut ids = HashSet::new();
    for value in list {
        let id = value
            .as_u64()
            .filter(|n| *n > 0)
            .ok_or(HarnessError::StaleReference)?;
        if !ids.insert(id) {
            return Err(HarnessError::StaleReference);
        }
    }
    Ok(ids)
}
fn role(raw: &str, has_backend: bool) -> &'static str {
    match raw {
        "RootWebArea" | "WebArea" => {
            if has_backend {
                "AXWebArea"
            } else {
                "AXDocument"
            }
        }
        "StaticText" | "InlineTextBox" => "AXStaticText",
        "heading" => "AXHeading",
        "textbox" | "searchbox" | "combobox" => "AXTextField",
        "button" | "togglebutton" => "AXButton",
        "link" => "AXLink",
        "checkbox" => "AXCheckBox",
        "radio" => "AXRadioButton",
        "tab" => "AXRadioButton",
        "dialog" | "alertdialog" => "AXWindow",
        "list" | "listbox" => "AXList",
        "table" | "grid" => "AXTable",
        _ => {
            if has_backend {
                "AXGroup"
            } else {
                "AXUnknown"
            }
        }
    }
}
fn project_observation(
    tree: &Value,
    dom: &Value,
    document: Document,
    generation: Uuid,
    identities: &mut HashMap<String, Uuid>,
    owned: bool,
) -> Result<Observation, HarnessError> {
    let nodes = tree["nodes"]
        .as_array()
        .filter(|n| n.len() <= 12_000)
        .ok_or(HarnessError::StaleReference)?;
    let evidence = &dom["mactopusClickability"];
    if evidence["frameId"] != document.frame || evidence["documentURL"] != document.url {
        return Err(HarnessError::StaleReference);
    }
    let clickable = id_set(&evidence["clickableBackendNodeIds"])?;
    let pointer = id_set(&evidence["pointerBackendNodeIds"])?;
    let empty = if evidence.get("emptyTextValueBackendNodeIds").is_some() {
        id_set(&evidence["emptyTextValueBackendNodeIds"])?
    } else {
        HashSet::new()
    };
    let mut links = HashMap::new();
    if let Some(list) = evidence["linkURLs"].as_array() {
        if list.len() > 12_000 {
            return Err(HarnessError::StaleReference);
        }
        for item in list {
            let id = item["backendNodeId"]
                .as_u64()
                .filter(|n| *n > 0)
                .ok_or(HarnessError::StaleReference)?;
            let url = item["url"]
                .as_str()
                .filter(|s| eligible_url(s, owned) && s.len() <= 16_384)
                .ok_or(HarnessError::StaleReference)?;
            if links.insert(id, url.to_owned()).is_some() {
                return Err(HarnessError::StaleReference);
            }
        }
    }
    let mut all_nodes = HashMap::new();
    for node in nodes {
        let id = node["nodeId"]
            .as_str()
            .ok_or(HarnessError::StaleReference)?;
        if all_nodes.insert(id, node).is_some() {
            return Err(HarnessError::StaleReference);
        }
    }
    let mut node_indices = HashMap::new();
    let mut backend_seen = HashSet::new();
    let mut eligible_nodes = vec![];
    let mut truncated = tree["macrouseSourceTruncated"] == true
        || tree["mactopusTruncated"] == true
        || evidence["sourceTruncated"] == true;
    for node in nodes {
        let node_id = node["nodeId"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 256)
            .ok_or(HarnessError::StaleReference)?;
        if node["ignored"] == true
            || node
                .get("frameId")
                .is_some_and(|f| f.as_str() != Some(&document.frame))
        {
            continue;
        }
        if node_indices
            .insert(node_id.to_owned(), eligible_nodes.len())
            .is_some()
        {
            return Err(HarnessError::StaleReference);
        }
        eligible_nodes.push(node);
    }
    if eligible_nodes.len() > 2000 {
        truncated = true;
        eligible_nodes.truncate(2000);
        node_indices.retain(|_, i| *i < 2000)
    }
    let mut elements = vec![];
    let mut backend = HashMap::new();
    for (index, node) in eligible_nodes.iter().enumerate() {
        let backend_id = node["backendDOMNodeId"].as_u64().filter(|n| *n > 0);
        if backend_id.is_some_and(|id| !backend_seen.insert(id)) {
            return Err(HarnessError::StaleReference);
        }
        let node_id = node["nodeId"].as_str().unwrap();
        let key = backend_id
            .map(|id| format!("dom:{id}"))
            .unwrap_or_else(|| format!("ax:{node_id}"));
        let identity = *identities.entry(key).or_insert_with(Uuid::new_v4);
        if let Some(id) = backend_id {
            backend.insert(identity, id);
        }
        let raw_role = ax_value(node, "role")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let disabled = property(node, "disabled")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let readonly = property(node, "readonly")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let editable = matches!(raw_role, "textbox" | "searchbox")
            || property(node, "editable")
                .is_some_and(|v| matches!(v.as_str(), Some("plaintext" | "richtext")));
        let settable = editable && !disabled && !readonly && backend_id.is_some();
        let press = !disabled
            && backend_id.is_some_and(|id| clickable.contains(&id) || pointer.contains(&id));
        let mut text_truncated = false;
        let mut text = |value: Option<&Value>| -> Option<String> {
            value.and_then(Value::as_str).map(|s| {
                let (b, t) = bounded(s, 16_384);
                text_truncated |= t;
                b
            })
        };
        let title = text(ax_value(node, "name"));
        let description = text(ax_value(node, "description"));
        let mut value = text(ax_value(node, "value"));
        if value.is_none() && settable && backend_id.is_some_and(|id| empty.contains(&id)) {
            value = Some(String::new())
        }
        let link_url = if raw_role == "link" {
            backend_id
                .and_then(|id| links.get(&id).cloned())
                .or_else(|| {
                    property(node, "url")
                        .and_then(Value::as_str)
                        .filter(|s| eligible_url(s, owned))
                        .map(str::to_owned)
                })
        } else {
            None
        };
        let mut parent_id = node["parentId"].as_str();
        let mut parent = None;
        let mut seen_parents = HashSet::new();
        while let Some(id) = parent_id {
            if !seen_parents.insert(id) || seen_parents.len() > 128 {
                return Err(HarnessError::StaleReference);
            }
            if let Some(index) = node_indices.get(id) {
                parent = Some(*index);
                break;
            }
            let Some(ignored) = all_nodes.get(id) else {
                truncated = true;
                break;
            };
            if ignored
                .get("frameId")
                .is_some_and(|frame| frame.as_str() != Some(&document.frame))
            {
                truncated = true;
                break;
            }
            parent_id = ignored["parentId"].as_str();
        }
        let children_truncated = node["childIds"].as_array().is_some_and(|ids| {
            ids.iter().any(|id| {
                id.as_str().is_none_or(|id| {
                    all_nodes.get(id).is_none_or(|child| {
                        child
                            .get("frameId")
                            .is_some_and(|frame| frame.as_str() != Some(&document.frame))
                    })
                })
            })
        });
        truncated |= children_truncated;
        elements.push(AxNode {
            index,
            parent_index: parent,
            identity,
            role: Some(role(raw_role, backend_id.is_some()).into()),
            subrole: Some(raw_role.into()),
            title,
            element_description: description,
            help: None,
            value,
            identifier: None,
            link_url,
            frame: None,
            is_enabled: Some(!disabled),
            is_selected: property(node, "selected").and_then(Value::as_bool),
            is_focused: property(node, "focused").and_then(Value::as_bool),
            is_value_settable: settable,
            actions: if press {
                vec!["AXPress".into()]
            } else {
                vec![]
            },
            children_truncated,
            text_truncated,
        });
    }
    // Parent cycles are untrusted protocol data, never traversed as a tree.
    for node in &elements {
        let mut current = node.parent_index;
        let mut seen = HashSet::from([node.index]);
        while let Some(index) = current {
            if !seen.insert(index) {
                return Err(HarnessError::StaleReference);
            }
            current = elements
                .get(index)
                .ok_or(HarnessError::StaleReference)?
                .parent_index;
        }
    }
    let snapshot = AxSnapshot {
        id: Uuid::new_v4(),
        target_generation: generation,
        window: WindowInfo {
            window_id: None,
            process_identifier: 0,
            bundle_identifier: Some("com.google.Chrome".into()),
            title: None,
            frame: None,
            is_main: true,
            is_focused: false,
            document: Some(document.url.clone()),
        },
        elements,
        source_truncated: truncated,
        captured_at: unix_time(),
    };
    Ok(Observation {
        snapshot,
        document,
        backend,
        owned,
    })
}
fn region_text(observation: &Observation, id: Uuid) -> Result<String, HarnessError> {
    let snapshot = &observation.snapshot;
    let node = snapshot
        .elements
        .iter()
        .find(|n| n.identity == id)
        .ok_or(HarnessError::StaleReference)?;
    if !node.is_region() || snapshot.source_truncated {
        return Err(HarnessError::StaleReference);
    }
    let descendants = snapshot.descendants(node.index);
    if descendants
        .iter()
        .any(|n| n.children_truncated || n.text_truncated)
    {
        return Err(HarnessError::StaleReference);
    }
    let text = descendants
        .into_iter()
        .filter(|n| {
            !snapshot
                .elements
                .iter()
                .any(|child| child.parent_index == Some(n.index))
        })
        .filter_map(|n| {
            [
                n.value.as_deref(),
                n.title.as_deref(),
                n.element_description.as_deref(),
            ]
            .into_iter()
            .flatten()
            .map(canonical)
            .find(|s| !s.is_empty())
        })
        .collect::<Vec<_>>()
        .join(" ");
    if text.len() > 8192 {
        return Err(HarnessError::StaleReference);
    }
    Ok(canonical(&text))
}
fn dialogs(observation: &Observation) -> Result<HashSet<Uuid>, HarnessError> {
    if observation.snapshot.source_truncated
        || observation
            .snapshot
            .elements
            .iter()
            .any(|n| n.children_truncated || n.text_truncated)
    {
        return Err(HarnessError::StaleReference);
    }
    Ok(observation
        .snapshot
        .elements
        .iter()
        .filter(|n| matches!(n.subrole.as_deref(), Some("dialog" | "alertdialog")))
        .map(|n| n.identity)
        .collect())
}
fn heading_matches(o: &Observation, expected: &str) -> Result<usize, HarnessError> {
    dialogs(o)?;
    Ok(o.snapshot
        .elements
        .iter()
        .filter(|n| n.is_heading() && n.title.as_deref().is_some_and(|s| canonical(s) == expected))
        .count())
}
fn document_root(o: &Observation) -> Result<Uuid, HarnessError> {
    let roots: Vec<_> = o
        .snapshot
        .elements
        .iter()
        .filter(|n| {
            n.parent_index.is_none()
                && n.role.as_deref() == Some("AXWebArea")
                && o.backend.contains_key(&n.identity)
        })
        .collect();
    if roots.len() != 1 {
        return Err(HarnessError::StaleReference);
    }
    Ok(roots[0].identity)
}
fn same_origin(a: &str, b: &str) -> bool {
    url::Url::parse(a)
        .ok()
        .zip(url::Url::parse(b).ok())
        .is_some_and(|(a, b)| {
            matches!(a.scheme(), "http" | "https")
                && a.scheme() == b.scheme()
                && a.host_str() == b.host_str()
                && a.port_or_known_default() == b.port_or_known_default()
        })
}
fn bounded_phrase(text: &str, expected: &str) -> bool {
    if expected.is_empty() {
        return false;
    }
    text.match_indices(expected).any(|(i, s)| {
        text[..i]
            .chars()
            .last()
            .is_none_or(|c| !c.is_alphanumeric() && c != '_')
            && text[i + s.len()..]
                .chars()
                .next()
                .is_none_or(|c| !c.is_alphanumeric() && c != '_')
    })
}
impl BrowserPlan {
    fn compile(
        o: &Observation,
        index: usize,
        exposed: &HashSet<usize>,
        text: Option<&str>,
        requested: Option<&Postcondition>,
        follow: bool,
    ) -> Result<Self, HarnessError> {
        let node = o.snapshot.node(index)?;
        let backend = *o
            .backend
            .get(&node.identity)
            .ok_or(HarnessError::StaleReference)?;
        if !exposed.contains(&index)
            || node.is_enabled == Some(false)
            || if text.is_some() {
                !node.is_value_settable
            } else {
                !node.has_action("AXPress")
            }
        {
            return Err(HarnessError::StaleReference);
        }
        let automatic = if let Some(text) = text {
            Some(Postcondition {
                kind: PostconditionKind::Value,
                element_index: Some(index),
                detail_element_index: None,
                expected: Some(text.into()),
            })
        } else if follow {
            Some(Postcondition {
                kind: PostconditionKind::DocumentUrl,
                element_index: None,
                detail_element_index: None,
                expected: node.link_url.clone(),
            })
        } else {
            None
        };
        let request = requested.or(automatic.as_ref()).ok_or_else(|| {
            HarnessError::Invalid(
                "Browser press requires a declared postcondition before input.".into(),
            )
        })?;
        if request.expected.as_ref().is_some_and(|s| s.len() > 4096) {
            return Err(HarnessError::Invalid("postcondition expected".into()));
        }
        let (kind, expected, region, baseline, dialog_baseline) = match request.kind {
            PostconditionKind::Value => {
                if text.is_none()
                    || request.expected.as_deref() != text
                    || request.element_index.is_some_and(|i| i != index)
                    || request.detail_element_index.is_some()
                {
                    return Err(HarnessError::Invalid("field value plan".into()));
                }
                let baseline = node
                    .value
                    .clone()
                    .filter(|_| !node.text_truncated)
                    .ok_or(HarnessError::StaleReference)?;
                (
                    request.kind,
                    request.expected.clone(),
                    Some(node.identity),
                    baseline,
                    HashSet::new(),
                )
            }
            PostconditionKind::DocumentUrl => {
                let expected = node
                    .link_url
                    .as_ref()
                    .filter(|s| eligible_url(s, o.owned) && Some(*s) == request.expected.as_ref())
                    .ok_or_else(|| {
                        HarnessError::Invalid(
                            "document_url must be the exact observed link destination".into(),
                        )
                    })?;
                if text.is_some()
                    || request.element_index.is_some()
                    || request.detail_element_index.is_some()
                {
                    return Err(HarnessError::Invalid("document URL plan".into()));
                }
                (
                    request.kind,
                    Some(expected.clone()),
                    None,
                    o.document.url.clone(),
                    HashSet::new(),
                )
            }
            PostconditionKind::RegionText | PostconditionKind::RegionChanged => {
                if text.is_some() {
                    return Err(HarnessError::Invalid("region plan for field setter".into()));
                }
                let target = if request.kind == PostconditionKind::DetailView {
                    if request.element_index.is_some() {
                        return Err(HarnessError::Invalid("detail region".into()));
                    }
                    request.detail_element_index
                } else {
                    if request.detail_element_index.is_some() {
                        return Err(HarnessError::Invalid("region detail".into()));
                    }
                    request.element_index
                }
                .ok_or_else(|| {
                    HarnessError::Invalid("postcondition requires an exposed region".into())
                })?;
                if !exposed.contains(&target) {
                    return Err(HarnessError::StaleReference);
                }
                let region = o.snapshot.node(target)?.identity;
                let baseline = region_text(o, region)?;
                let expected = if request.kind == PostconditionKind::RegionChanged {
                    if request.expected.as_deref().is_some_and(|s| s != "changed") {
                        return Err(HarnessError::Invalid(
                            "region_changed expects changed".into(),
                        ));
                    }
                    let target_node = o.snapshot.node(target)?;
                    if target == index
                        || target_node.is_value_settable
                        || !target_node.actions.is_empty()
                    {
                        return Err(HarnessError::Invalid(
                            "region_changed requires a distinct read-only region".into(),
                        ));
                    }
                    Some("changed".into())
                } else {
                    Some(canonical(
                        request
                            .expected
                            .as_deref()
                            .filter(|s| !s.trim().is_empty())
                            .ok_or_else(|| HarnessError::Invalid("expected region text".into()))?,
                    ))
                };
                (
                    request.kind,
                    expected,
                    Some(region),
                    baseline,
                    HashSet::new(),
                )
            }
            PostconditionKind::DetailView => {
                if text.is_some()
                    || request.element_index.is_some()
                    || request.detail_element_index.is_some()
                {
                    return Err(HarnessError::Invalid("browser detail_view requires the action's observed text, without a guessed destination region".into()));
                }
                let expected = canonical(
                    request
                        .expected
                        .as_deref()
                        .filter(|s| !s.trim().is_empty())
                        .ok_or_else(|| HarnessError::Invalid("detail heading".into()))?,
                );
                let descendants = o.snapshot.descendants(index);
                if !descendants
                    .iter()
                    .flat_map(|n| {
                        [
                            n.title.as_deref(),
                            n.element_description.as_deref(),
                            n.value.as_deref(),
                        ]
                    })
                    .flatten()
                    .any(|s| bounded_phrase(&canonical(s), &expected))
                {
                    return Err(HarnessError::Invalid(
                        "detail heading must occur in the observed action target".into(),
                    ));
                }
                if heading_matches(o, &expected)? != 0 {
                    return Err(HarnessError::Invalid(
                        "detail heading is already present; no input needed".into(),
                    ));
                }
                (
                    request.kind,
                    Some(expected),
                    None,
                    format!("heading_absent:{}", o.document.url),
                    HashSet::new(),
                )
            }
            PostconditionKind::DialogOpened => {
                if text.is_some()
                    || request.expected.as_deref().is_some_and(|s| s != "opened")
                    || request.element_index.is_some()
                    || request.detail_element_index.is_some()
                    || !matches!(node.subrole.as_deref(), Some("button" | "menuitem"))
                    || node.is_value_settable
                    || node.link_url.is_some()
                {
                    return Err(HarnessError::Invalid("dialog_opened requires an observed button/menuitem opener and expects opened".into()));
                }
                let baseline = dialogs(o)?;
                if !baseline.is_empty() {
                    return Err(HarnessError::Invalid(
                        "a dialog is already present; no opener input was sent".into(),
                    ));
                }
                document_root(o)?;
                (
                    request.kind,
                    Some("opened".into()),
                    None,
                    String::new(),
                    baseline,
                )
            }
            PostconditionKind::Selection => {
                return Err(HarnessError::Capability(
                    "Browser selection proof is not represented by the safe DOM operations.".into(),
                ));
            }
        };
        let already_satisfied = expected.as_ref().is_some_and(|e| *e == baseline);
        Ok(Self {
            kind,
            attachment_generation: o.snapshot.target_generation,
            owned: o.owned,
            document: o.document.clone(),
            action: node.identity,
            backend,
            role: node.role.clone(),
            label: node.label(),
            action_value: node.value.clone(),
            region,
            expected,
            baseline,
            dialog_baseline,
            root: if kind == PostconditionKind::DialogOpened {
                Some(document_root(o)?)
            } else {
                None
            },
            already_satisfied,
        })
    }
    fn revalidate(&self, o: &Observation) -> Result<(), HarnessError> {
        if o.document != self.document
            || o.snapshot.target_generation != self.attachment_generation
            || o.owned != self.owned
        {
            return Err(HarnessError::StaleReference);
        }
        let node = o
            .snapshot
            .elements
            .iter()
            .find(|n| {
                n.identity == self.action && o.backend.get(&n.identity) == Some(&self.backend)
            })
            .ok_or(HarnessError::StaleReference)?;
        if node.role != self.role
            || node.label() != self.label
            || node.value != self.action_value
            || node.is_enabled == Some(false)
        {
            return Err(HarnessError::StaleReference);
        }
        let baseline = match self.kind {
            PostconditionKind::Value => node.value.clone().ok_or(HarnessError::StaleReference)?,
            PostconditionKind::DocumentUrl => {
                if node.link_url != self.expected {
                    return Err(HarnessError::StaleReference);
                }
                o.document.url.clone()
            }
            PostconditionKind::RegionText | PostconditionKind::RegionChanged => {
                region_text(o, self.region.unwrap())?
            }
            PostconditionKind::DetailView => {
                if heading_matches(o, self.expected.as_ref().unwrap())? != 0 {
                    return Err(HarnessError::StaleReference);
                }
                format!("heading_absent:{}", o.document.url)
            }
            PostconditionKind::DialogOpened => {
                if dialogs(o)? != self.dialog_baseline {
                    return Err(HarnessError::StaleReference);
                }
                String::new()
            }
            _ => return Err(HarnessError::StaleReference),
        };
        if baseline != self.baseline {
            return Err(HarnessError::StaleReference);
        }
        Ok(())
    }
    fn evaluate(&self, o: &Observation) -> Result<(), HarnessError> {
        if o.snapshot.target_generation != self.attachment_generation || o.owned != self.owned {
            return Err(HarnessError::StaleReference);
        }
        if self.kind == PostconditionKind::DocumentUrl {
            if o.document.frame == self.document.frame
                && Some(&o.document.url) == self.expected.as_ref()
            {
                return Ok(());
            }
            return Err(HarnessError::StaleReference);
        }
        if self.kind == PostconditionKind::DetailView {
            let expected = self.expected.as_ref().ok_or(HarnessError::StaleReference)?;
            if o.document.url != self.document.url
                && same_origin(&o.document.url, &self.document.url)
                && heading_matches(o, expected)? == 1
            {
                return Ok(());
            }
            return Err(HarnessError::StaleReference);
        }
        if o.document != self.document {
            return Err(HarnessError::StaleReference);
        }
        let observed = match self.kind {
            PostconditionKind::Value => o
                .snapshot
                .elements
                .iter()
                .find(|n| {
                    n.identity == self.action
                        && o.backend.get(&n.identity) == Some(&self.backend)
                        && n.role == self.role
                        && !n.text_truncated
                })
                .and_then(|n| n.value.clone())
                .ok_or(HarnessError::StaleReference)?,
            PostconditionKind::RegionText | PostconditionKind::DetailView => {
                region_text(o, self.region.unwrap())?
            }
            PostconditionKind::RegionChanged => {
                let current = region_text(o, self.region.unwrap())?;
                if current != self.baseline {
                    return Ok(());
                }
                return Err(HarnessError::StaleReference);
            }
            PostconditionKind::DialogOpened => {
                let now = dialogs(o)?;
                if Some(document_root(o)?) == self.root
                    && now.len() == 1
                    && now.difference(&self.dialog_baseline).count() == 1
                {
                    return Ok(());
                }
                return Err(HarnessError::StaleReference);
            }
            _ => return Err(HarnessError::StaleReference),
        };
        if Some(&observed) == self.expected.as_ref() {
            Ok(())
        } else {
            Err(HarnessError::StaleReference)
        }
    }
}
fn receipt_output(r: &Receipt) -> ToolOutput {
    let success = matches!(r.status, "verified" | "already_satisfied");
    ToolOutput::text(
        format!(
            "ACTION_EVIDENCE operation_id={} dispatch={} status={} verification_reads={} property={} expected={}{}\n{}",
            r.id,
            serde_json::to_value(&r.dispatch).unwrap().as_str().unwrap(),
            r.status,
            r.reads,
            serde_json::to_value(r.plan.kind).unwrap().as_str().unwrap(),
            json!(r.plan.expected),
            r.failure
                .as_ref()
                .map(|f| format!(" failure={}", json!(f)))
                .unwrap_or_default(),
            if success {
                "This proves only the declared property; read actual destination/content before claiming whole-task completion."
            } else {
                "Outcome remains unverified. No action was repeated. Only bounded read-only recovery is permitted."
            }
        ),
        success,
    )
}

/// Routes the ordinary, paired Chrome lane and a task-owned isolated process.
/// Only owned-process cleanup can terminate a browser; borrowed tabs are detached.
pub struct RoutingBrowserLane {
    borrowed: Option<ChromeBrowserLane>,
    owned: Option<ChromeBrowserLane>,
    owned_controller: Option<Arc<computa_browser::owned::OwnedBrowserController>>,
    profile_parent: std::path::PathBuf,
    use_owned: bool,
    authority: Option<TurnAuthority>,
}
impl RoutingBrowserLane {
    /// Trusted host diagnostics can independently inspect the exact owned
    /// controller before its cleanup. No model reference or borrowed session
    /// can select this handle, and the controller retains its native grant.
    pub fn owned_controller(&self) -> Option<Arc<dyn BrowserControl>> {
        self.owned_controller
            .as_ref()
            .map(|controller| controller.clone() as Arc<dyn BrowserControl>)
    }
    pub fn owned_qualification_receipt(&self) -> Option<(Arc<dyn BrowserControl>, Attachment)> {
        Some((
            self.owned_controller()?,
            self.owned.as_ref()?.attachment.clone()?,
        ))
    }
    pub fn new(
        borrowed: Option<Arc<dyn BrowserControl>>,
        profile_parent: std::path::PathBuf,
    ) -> Self {
        Self {
            borrowed: borrowed.map(ChromeBrowserLane::new),
            owned: None,
            owned_controller: None,
            profile_parent,
            use_owned: false,
            authority: None,
        }
    }
    fn active(&mut self) -> Result<&mut ChromeBrowserLane, HarnessError> {
        if self.use_owned {
            self.owned.as_mut()
        } else {
            self.borrowed.as_mut()
        }
        .ok_or_else(|| {
            HarnessError::Browser(
                "Chrome is not connected. Use the native Chrome connection controls.".into(),
            )
        })
    }
}
impl BrowserToolLane for RoutingBrowserLane {
    fn set_turn_authority(&mut self, authority: TurnAuthority) {
        if let Some(lane) = &mut self.borrowed {
            lane.set_turn_authority(authority.clone())
        }
        if let Some(lane) = &mut self.owned {
            lane.set_turn_authority(authority.clone())
        }
        self.authority = Some(authority)
    }
    fn is_borrowed(&self) -> bool {
        !self.use_owned
    }
    fn operation_count(&self) -> usize {
        self.borrowed.as_ref().map_or(0, |lane| lane.receipts.len())
            + self.owned.as_ref().map_or(0, |lane| lane.receipts.len())
    }
    fn outcome_counts(&self) -> (u64, u64) {
        let a = self
            .borrowed
            .as_ref()
            .map_or((0, 0), BrowserToolLane::outcome_counts);
        let b = self
            .owned
            .as_ref()
            .map_or((0, 0), BrowserToolLane::outcome_counts);
        (a.0 + b.0, a.1 + b.1)
    }
    fn open_isolated<'a>(
        &'a mut self,
        scope: &'a ExecutionScope,
        executable: std::path::PathBuf,
        url: &'a str,
        cancel: &'a CancellationToken,
    ) -> LocalFuture<'a, Result<crate::executor::OwnedBrowserBinding, HarnessError>> {
        Box::pin(async move {
            if cancel.is_cancelled() {
                return Err(HarnessError::Cancelled);
            }
            if self.owned.is_some() {
                return Err(HarnessError::Browser(
                    "This turn already owns an isolated browser. No second process was launched."
                        .into(),
                ));
            }
            let controller = computa_browser::owned::OwnedBrowserController::launch(
                executable,
                self.profile_parent.clone(),
                url,
                scope.generation,
            )
            .await
            .map_err(browser_error)?;
            self.owned_controller = Some(controller.clone());
            let mut lane = ChromeBrowserLane::new(controller.clone());
            if let Some(authority) = &self.authority {
                lane.set_turn_authority(authority.clone())
            }
            lane.check(scope, cancel)?;
            let mut attachment = None;
            for attempt in 0..50 {
                if cancel.is_cancelled() {
                    self.owned = Some(lane);
                    return Err(HarnessError::Cancelled);
                }
                let inventory = controller.inventory().await.map_err(browser_error)?;
                if inventory.len() == 1 && inventory[0].availability == "available" {
                    attachment = Some(
                        controller
                            .attach(&inventory[0].target_id)
                            .await
                            .map_err(browser_error)?,
                    );
                    break;
                }
                if inventory.len() > 1 {
                    self.owned = Some(lane);
                    return Err(HarnessError::Browser("The new private browser exposed multiple candidate pages; no page was guessed.".into()));
                }
                if attempt < 49 {
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
            }
            lane.attachment = attachment;
            let pid = controller.pid();
            let executable = controller.executable_path().to_owned();
            let bound = lane.attachment.is_some();
            self.owned = Some(lane);
            if !bound {
                return Err(HarnessError::Browser("The exact private Chrome page was not ready; its owned process remains tracked for cleanup.".into()));
            }
            self.use_owned = true;
            Ok(crate::executor::OwnedBrowserBinding {
                process_identifier: i32::try_from(pid).map_err(|_| HarnessError::StaleReference)?,
                executable,
            })
        })
    }
    fn execute<'a>(
        &'a mut self,
        scope: &'a ExecutionScope,
        name: &'a str,
        args: Value,
        approval: &'a mut dyn ApprovalGate,
        cancel: &'a CancellationToken,
    ) -> LocalFuture<'a, Result<ToolOutput, HarnessError>> {
        Box::pin(async move {
            let borrowed_inventory = name == "computer_v2_tabs"
                || name == "computer_v2_continue"
                    && args["cursor"]
                        .as_str()
                        .and_then(|s| Uuid::parse_str(s).ok())
                        .is_some_and(|id| {
                            self.borrowed
                                .as_ref()
                                .and_then(|lane| lane.inventory.as_ref())
                                .is_some_and(|page| page.cursor == id)
                        });
            let borrowed_binding = matches!(
                name,
                "computer_v2_bind_tab" | "computer_v2_create_workspace"
            ) && args["candidate_token"].as_str().is_some_and(|token| {
                self.borrowed
                    .as_ref()
                    .is_some_and(|lane| lane.candidates.contains_key(token))
            });
            if (borrowed_inventory || borrowed_binding)
                && let Some(borrowed) = self.borrowed.as_mut()
            {
                let output = borrowed
                    .execute(scope, name, args, approval, cancel)
                    .await?;
                if borrowed_binding && output.success {
                    self.use_owned = false
                }
                return Ok(output);
            }
            self.active()?
                .execute(scope, name, args, approval, cancel)
                .await
        })
    }
    fn end_turn<'a>(&'a mut self, scope: &'a ExecutionScope) -> LocalFuture<'a, Vec<String>> {
        Box::pin(async move {
            let mut issues = vec![];
            if let Some(lane) = &mut self.borrowed {
                issues.extend(lane.end_turn(scope).await)
            }
            if let Some(lane) = &mut self.owned {
                issues.extend(lane.end_turn(scope).await)
            }
            if let Some(controller) = self.owned_controller.take() {
                for warning in controller.shutdown().await {
                    issues.push(format!("Owned Chrome cleanup was not confirmed: {warning}"));
                }
            }
            self.use_owned = false;
            issues
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn browser_default_view_does_not_hide_literal_query_or_subtree_content() {
        let mut whole = ReadArgs::default();
        default_browser_view(&mut whole);
        assert_eq!(whole.view, Some(ReadView::Overview));
        let mut query = ReadArgs {
            query: Some("Exact article text".into()),
            ..Default::default()
        };
        default_browser_view(&mut query);
        assert_eq!(query.view, Some(ReadView::All));
        let mut subtree = ReadArgs {
            snapshot_id: Some(Uuid::new_v4().to_string()),
            element_index: Some(42),
            ..Default::default()
        };
        default_browser_view(&mut subtree);
        assert_eq!(subtree.view, Some(ReadView::All));
        let mut continuation = ReadArgs {
            cursor: Some(Uuid::new_v4().to_string()),
            ..Default::default()
        };
        default_browser_view(&mut continuation);
        assert_eq!(continuation.view, None);
    }
    #[test]
    fn inventory_pages_only_authorize_published_tokens_and_exhaust_without_silent_omission() {
        let items: Vec<_> = (0..40)
            .map(|i| {
                (
                    format!("token-{i}"),
                    Candidate {
                        target_id: format!("target-{i}"),
                        title: "é".repeat(128),
                        url: format!("https://example.com/{}", "x".repeat(2048)),
                        availability: "available".into(),
                    },
                )
            })
            .collect();
        let mut page = Inventory {
            items: items.clone(),
            next: 0,
            cursor: Uuid::new_v4(),
            page_size: 100,
        };
        let mut published = HashMap::new();
        let first = publish_inventory_page(&mut page, &mut published).unwrap();
        assert!(first.len() <= 12_288);
        assert!(page.next > 0 && page.next < items.len());
        assert_eq!(published.len(), page.next);
        assert!(!published.contains_key(&items[page.next].0));
        while page.next < page.items.len() {
            let text = publish_inventory_page(&mut page, &mut published).unwrap();
            assert!(!text.is_empty() && text.len() <= 12_288);
        }
        assert_eq!(published.len(), items.len());
        for (token, candidate) in items {
            assert_eq!(published[&token].target_id, candidate.target_id);
        }
    }
    fn fixture() -> (Value, Value, Document) {
        let doc = Document {
            frame: "f".into(),
            loader: "l".into(),
            url: "https://example.com/".into(),
        };
        let tree = json!({"nodes":[{"nodeId":"1","backendDOMNodeId":1,"frameId":"f","role":{"value":"RootWebArea"},"childIds":["2","3"]},{"nodeId":"2","parentId":"1","backendDOMNodeId":2,"frameId":"f","role":{"value":"textbox"},"name":{"value":"Search"},"properties":[{"name":"editable","value":{"value":"plaintext"}}]},{"nodeId":"3","parentId":"1","backendDOMNodeId":3,"frameId":"f","role":{"value":"button"},"name":{"value":"Go"}}],"macrouseSourceTruncated":false});
        let dom = json!({"mactopusClickability":{"frameId":"f","documentURL":"https://example.com/","clickableBackendNodeIds":[3],"pointerBackendNodeIds":[],"emptyTextValueBackendNodeIds":[2],"sourceTruncated":false}});
        (tree, dom, doc)
    }
    #[test]
    fn backend_ids_and_empty_field_evidence_are_exact_and_frame_scoped() {
        let (t, d, doc) = fixture();
        let generation = Uuid::new_v4();
        let mut identities = HashMap::new();
        let a =
            project_observation(&t, &d, doc.clone(), generation, &mut identities, false).unwrap();
        let b =
            project_observation(&t, &d, doc.clone(), generation, &mut identities, false).unwrap();
        assert_eq!(
            a.snapshot.elements[1].identity,
            b.snapshot.elements[1].identity
        );
        assert_eq!(a.snapshot.elements[1].value.as_deref(), Some(""));
        assert!(a.snapshot.elements[1].is_value_settable);
        assert!(!a.snapshot.elements[1].has_action("AXPress"));
        assert!(a.snapshot.elements[2].has_action("AXPress"));
        let mut wrong = d;
        wrong["mactopusClickability"]["frameId"] = json!("other");
        assert!(project_observation(&t, &wrong, doc, generation, &mut identities, false).is_err());
    }
    #[test]
    fn field_plan_revalidates_before_input_and_cannot_follow_labels() {
        let (t, d, doc) = fixture();
        let generation = Uuid::new_v4();
        let mut identities = HashMap::new();
        let a = project_observation(&t, &d, doc, generation, &mut identities, false).unwrap();
        let plan =
            BrowserPlan::compile(&a, 1, &HashSet::from([1]), Some("hello"), None, false).unwrap();
        assert!(plan.revalidate(&a).is_ok());
        let mut changed = a.clone();
        changed.snapshot.id = Uuid::new_v4();
        changed.snapshot.elements[1].value = Some("someone else".into());
        assert!(plan.revalidate(&changed).is_err());
        changed.snapshot.elements[1].value = Some("hello".into());
        assert!(plan.evaluate(&changed).is_ok());
        let original_generation = changed.snapshot.target_generation;
        changed.snapshot.target_generation = Uuid::new_v4();
        assert!(plan.evaluate(&changed).is_err());
        assert!(plan.revalidate(&changed).is_err());
        changed.snapshot.target_generation = original_generation;
        changed.snapshot.elements[1].identity = Uuid::new_v4();
        assert!(plan.evaluate(&changed).is_err());
    }
    #[test]
    fn clicks_without_precompiled_result_are_rejected_and_truncation_cannot_prove_dialog() {
        let (t, d, doc) = fixture();
        let mut ids = HashMap::new();
        let mut a = project_observation(&t, &d, doc, Uuid::new_v4(), &mut ids, false).unwrap();
        assert!(BrowserPlan::compile(&a, 2, &HashSet::from([2]), None, None, false).is_err());
        let request = Postcondition {
            kind: PostconditionKind::DialogOpened,
            element_index: None,
            detail_element_index: None,
            expected: None,
        };
        a.snapshot.source_truncated = true;
        assert!(
            BrowserPlan::compile(&a, 2, &HashSet::from([2]), None, Some(&request), false).is_err()
        );
    }
    #[test]
    fn file_documents_and_observed_links_require_owned_process_authority() {
        let file_url = "file:///tmp/observed.html";
        let frame = json!({"frameTree":{"frame":{"id":"f","loaderId":"l","url":file_url}}});
        assert!(document_from(&frame, false).is_err());
        let doc = document_from(&frame, true).unwrap();
        let (mut tree, mut dom, _) = fixture();
        tree["nodes"][2]["role"]["value"] = json!("link");
        dom["mactopusClickability"]["documentURL"] = json!(file_url);
        dom["mactopusClickability"]["linkURLs"] =
            json!([{"backendNodeId":3,"url":"file:///tmp/destination.html"}]);
        assert!(
            project_observation(
                &tree,
                &dom,
                doc.clone(),
                Uuid::new_v4(),
                &mut HashMap::new(),
                false
            )
            .is_err()
        );
        let observed =
            project_observation(&tree, &dom, doc, Uuid::new_v4(), &mut HashMap::new(), true)
                .unwrap();
        assert_eq!(
            observed.snapshot.elements[2].link_url.as_deref(),
            Some("file:///tmp/destination.html")
        );
        let plan =
            BrowserPlan::compile(&observed, 2, &HashSet::from([2]), None, None, true).unwrap();
        let mut destination = observed.clone();
        destination.document.url = "file:///tmp/destination.html".into();
        destination.document.loader = "new-document".into();
        assert!(plan.evaluate(&destination).is_ok());
        assert!(!same_origin(file_url, "file:///tmp/destination.html"));
    }
    #[test]
    fn future_or_subframe_links_never_gain_document_navigation_authority() {
        let (t, d, doc) = fixture();
        let mut ids = HashMap::new();
        let mut a = project_observation(&t, &d, doc, Uuid::new_v4(), &mut ids, false).unwrap();
        a.snapshot.elements[2].link_url = Some("https://example.com/actual".into());
        let request = Postcondition {
            kind: PostconditionKind::DocumentUrl,
            expected: Some("https://example.com/guessed".into()),
            element_index: None,
            detail_element_index: None,
        };
        assert!(
            BrowserPlan::compile(&a, 2, &HashSet::from([2]), None, Some(&request), false).is_err()
        );
    }
}
