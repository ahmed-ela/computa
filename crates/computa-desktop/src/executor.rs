//! Main-thread ownership boundary for the Send runtime dispatcher.
use crate::grounder::NativeGroundingService;
use crate::native::DesktopEvent;
use computa_contracts::{
    Identifier,
    appserver::{DispatchError, ExecutionScope, TurnConclusion},
    ui::AccessMode,
};
use computa_harness::{
    ApprovalGate, Harness, HarnessError, LocalFuture, NativeApproval,
    evidence::FailureEvidenceStore,
};
use computa_macos::NativeBackend;
use computa_runtime::NativeCommand;
use futures::{executor::LocalPool, task::LocalSpawnExt};
use std::{
    cell::{Cell, RefCell},
    collections::{HashMap, VecDeque},
    future::Future,
    path::PathBuf,
    pin::Pin,
    rc::Rc,
    sync::Arc,
    task::{Context, Poll, Wake, Waker},
};
use tao::event_loop::EventLoopProxy;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

struct UiWake {
    inner: Waker,
    proxy: EventLoopProxy<DesktopEvent>,
}
impl Wake for UiWake {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }
    fn wake_by_ref(self: &Arc<Self>) {
        self.inner.wake_by_ref();
        let _ = self.proxy.send_event(DesktopEvent::Wake);
    }
}
struct EventFuture<F> {
    future: Pin<Box<F>>,
    proxy: EventLoopProxy<DesktopEvent>,
}
impl<F: Future> Future for EventFuture<F> {
    type Output = F::Output;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.get_mut();
        let waker = Waker::from(Arc::new(UiWake {
            inner: cx.waker().clone(),
            proxy: this.proxy.clone(),
        }));
        this.future.as_mut().poll(&mut Context::from_waker(&waker))
    }
}

struct Gate {
    proxy: EventLoopProxy<DesktopEvent>,
    mode: Rc<Cell<AccessMode>>,
}
struct PromptLifetime {
    proxy: EventLoopProxy<DesktopEvent>,
    id: String,
}
impl Drop for PromptLifetime {
    fn drop(&mut self) {
        let _ = self
            .proxy
            .send_event(DesktopEvent::ApprovalExpired(self.id.clone()));
    }
}
impl ApprovalGate for Gate {
    fn approve<'a>(
        &'a mut self,
        request: NativeApproval,
    ) -> LocalFuture<'a, Result<bool, HarnessError>> {
        Box::pin(async move {
            if self.mode.get() == AccessMode::FullAccess {
                return Ok(true);
            }
            let id = request.id.clone();
            let (reply, result) = oneshot::channel();
            self.proxy
                .send_event(DesktopEvent::HarnessApproval { request, reply })
                .map_err(|_| HarnessError::Cancelled)?;
            let _lifetime = PromptLifetime {
                proxy: self.proxy.clone(),
                id,
            };
            result.await.map_err(|_| HarnessError::Cancelled)
        })
    }
}
struct Slot {
    scope: ExecutionScope,
    harness: Harness<NativeBackend>,
    cancellation: CancellationToken,
}
pub struct Executor {
    queue: VecDeque<NativeCommand>,
    slots: Rc<RefCell<HashMap<Identifier, Slot>>>,
    pool: LocalPool,
    active: Rc<Cell<bool>>,
    proxy: EventLoopProxy<DesktopEvent>,
    mode: Rc<Cell<AccessMode>>,
    evidence: PathBuf,
    models: HashMap<Identifier, bool>,
    grounder: Arc<NativeGroundingService>,
}
impl Executor {
    pub fn new(
        proxy: EventLoopProxy<DesktopEvent>,
        mode: Rc<Cell<AccessMode>>,
        evidence: PathBuf,
        grounder: Arc<NativeGroundingService>,
    ) -> Self {
        Self {
            queue: VecDeque::new(),
            slots: Rc::new(RefCell::new(HashMap::new())),
            pool: LocalPool::new(),
            active: Rc::new(Cell::new(false)),
            proxy,
            mode,
            evidence,
            models: HashMap::new(),
            grounder,
        }
    }
    pub fn set_models(&mut self, models: HashMap<Identifier, bool>) {
        self.models = models;
    }
    pub fn push(&mut self, command: NativeCommand) {
        self.queue.push_back(command);
    }
    pub fn pending(&self) -> bool {
        self.active.get() || !self.queue.is_empty()
    }
    pub fn revoke_all(&self) {
        for slot in self.slots.borrow().values() {
            slot.cancellation.cancel();
            slot.harness.authority().revoke();
        }
    }
    /// Poll only while work exists. The macOS event loop continues pumping
    /// AppKit callbacks while native AX/open/screenshot futures await results.
    pub fn pump(&mut self, handle: &tokio::runtime::Handle) {
        let _entered = handle.enter();
        self.pool.run_until_stalled();
        if self.active.get() {
            return;
        }
        let Some(command) = self.queue.pop_front() else {
            return;
        };
        match command {
            NativeCommand::Begin {
                scope,
                cancellation,
                reply,
            } => {
                let result = (|| {
                    if cancellation.is_cancelled()
                        || self.slots.borrow().contains_key(&scope.task_id)
                    {
                        return Err(DispatchError::StaleScope);
                    }
                    let backend = NativeBackend::new().map_err(|_| DispatchError::Unavailable)?;
                    let mut harness = Harness::new(backend, scope.policy);
                    let store = FailureEvidenceStore::open(self.evidence.clone())
                        .map_err(|_| DispatchError::Unavailable)?;
                    harness.set_failure_store(store);
                    harness.set_browser_model(
                        self.models.get(&scope.task_id).copied().unwrap_or(false),
                    );
                    harness
                        .begin_turn(scope.clone())
                        .map_err(|_| DispatchError::StaleScope)?;
                    self.slots.borrow_mut().insert(
                        scope.task_id.clone(),
                        Slot {
                            scope,
                            harness,
                            cancellation,
                        },
                    );
                    Ok(())
                })();
                let _ = reply.send(result);
            }
            NativeCommand::Execute {
                scope,
                call_id,
                name,
                arguments,
                cancellation,
                reply,
            } => {
                if self
                    .slots
                    .borrow()
                    .get(&scope.task_id)
                    .is_none_or(|slot| slot.scope != scope)
                {
                    let _ = reply.send(Err(DispatchError::StaleScope));
                    return;
                }
                let slot = self.slots.borrow_mut().remove(&scope.task_id);
                let Some(mut slot) = slot.filter(|s| s.scope == scope) else {
                    let _ = reply.send(Err(DispatchError::StaleScope));
                    return;
                };
                if cancellation.is_cancelled() || slot.cancellation.is_cancelled() {
                    self.slots.borrow_mut().insert(scope.task_id.clone(), slot);
                    let _ = reply.send(Err(DispatchError::StaleScope));
                    return;
                }
                self.active.set(true);
                let slots = self.slots.clone();
                let active = self.active.clone();
                let proxy = self.proxy.clone();
                let mode = self.mode.clone();
                let grounder = self.grounder.clone();
                self.pool
                    .spawner()
                    .spawn_local(EventFuture {
                        proxy: self.proxy.clone(),
                        future: Box::pin(async move {
                            let mut gate = Gate {
                                proxy: proxy.clone(),
                                mode,
                            };
                            let mut grounder =
                                grounder.for_turn(scope.generation, slot.harness.authority());
                            let output = slot
                                .harness
                                .execute(
                                    &scope,
                                    &call_id,
                                    &name,
                                    arguments,
                                    &cancellation,
                                    &mut gate,
                                    &mut grounder,
                                )
                                .await;
                            slots.borrow_mut().insert(scope.task_id.clone(), slot);
                            active.set(false);
                            let _ = reply.send(Ok(output));
                            let _ = proxy.send_event(DesktopEvent::Wake);
                        }),
                    })
                    .expect("live local executor");
            }
            NativeCommand::End { scope, reply } => {
                if self
                    .slots
                    .borrow()
                    .get(&scope.task_id)
                    .is_none_or(|slot| slot.scope != scope)
                {
                    let _ = reply.send(TurnConclusion {
                        unresolved_operations: 1,
                        failed_operations: 0,
                    });
                    return;
                }
                let slot = self.slots.borrow_mut().remove(&scope.task_id);
                let Some(mut slot) = slot.filter(|s| s.scope == scope) else {
                    let _ = reply.send(TurnConclusion {
                        unresolved_operations: 1,
                        failed_operations: 0,
                    });
                    return;
                };
                slot.cancellation.cancel();
                slot.harness.authority().revoke();
                self.active.set(true);
                let active = self.active.clone();
                let proxy = self.proxy.clone();
                self.pool
                    .spawner()
                    .spawn_local(EventFuture {
                        proxy: self.proxy.clone(),
                        future: Box::pin(async move {
                            let (a, b) = slot.harness.outcome_counts();
                            let issues = slot.harness.end_turn().await;
                            let unresolved = a.max(u64::from(!issues.is_empty()));
                            let failed = b;
                            let _ = reply.send(TurnConclusion {
                                unresolved_operations: unresolved,
                                failed_operations: failed,
                            });
                            active.set(false);
                            let _ = proxy.send_event(DesktopEvent::Wake);
                        }),
                    })
                    .expect("live local executor");
            }
        }
        self.pool.run_until_stalled();
        if !self.queue.is_empty() && !self.active.get() {
            let _ = self.proxy.send_event(DesktopEvent::Wake);
        }
    }
}
impl Drop for Executor {
    fn drop(&mut self) {
        self.revoke_all();
    }
}
