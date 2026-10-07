//! Send-only channel facade for a non-Send native main-thread harness.
//! The receiver owns all AX state; this module carries JSON and cancellation only.
use async_trait::async_trait;
use computa_contracts::{Identifier, appserver::*};
use serde_json::Value;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;
pub enum NativeCommand {
    Begin {
        scope: ExecutionScope,
        cancellation: CancellationToken,
        reply: oneshot::Sender<Result<(), DispatchError>>,
    },
    Execute {
        scope: ExecutionScope,
        call_id: Identifier,
        name: String,
        arguments: Value,
        cancellation: CancellationToken,
        reply: oneshot::Sender<Result<ToolOutput, DispatchError>>,
    },
    End {
        scope: ExecutionScope,
        reply: oneshot::Sender<TurnConclusion>,
    },
}
struct Scope {
    scope: ExecutionScope,
    cancellation: CancellationToken,
}
pub struct ChannelToolDispatcher {
    sender: mpsc::UnboundedSender<NativeCommand>,
    scopes: Mutex<HashMap<Identifier, Scope>>,
}
impl ChannelToolDispatcher {
    pub fn channel() -> (Arc<Self>, mpsc::UnboundedReceiver<NativeCommand>) {
        let (sender, receiver) = mpsc::unbounded_channel();
        (
            Arc::new(Self {
                sender,
                scopes: Mutex::new(HashMap::new()),
            }),
            receiver,
        )
    }
    /// Revoke synchronously before a UI-thread End command is queued. This is
    /// also usable by native window-close controls while an approval awaits.
    pub fn revoke(&self, scope: &ExecutionScope) {
        if let Ok(scopes) = self.scopes.lock()
            && let Some(slot) = scopes.get(&scope.task_id).filter(|s| s.scope == *scope)
        {
            slot.cancellation.cancel();
        }
    }
    pub fn revoke_all(&self) {
        if let Ok(scopes) = self.scopes.lock() {
            for slot in scopes.values() {
                slot.cancellation.cancel();
            }
        }
    }
}
#[async_trait]
impl ToolDispatcher for ChannelToolDispatcher {
    async fn begin_turn(&self, scope: ExecutionScope) -> Result<(), DispatchError> {
        let token = CancellationToken::new();
        {
            let mut scopes = self.scopes.lock().map_err(|_| DispatchError::Unavailable)?;
            if scopes.contains_key(&scope.task_id) {
                return Err(DispatchError::StaleScope);
            }
            scopes.insert(
                scope.task_id.clone(),
                Scope {
                    scope: scope.clone(),
                    cancellation: token.clone(),
                },
            );
        }
        let (reply, result) = oneshot::channel();
        if self
            .sender
            .send(NativeCommand::Begin {
                scope: scope.clone(),
                cancellation: token,
                reply,
            })
            .is_err()
        {
            self.revoke(&scope);
            self.scopes
                .lock()
                .map_err(|_| DispatchError::Unavailable)?
                .remove(&scope.task_id);
            return Err(DispatchError::Unavailable);
        }
        match result.await {
            Ok(Ok(())) => Ok(()),
            value => {
                self.revoke(&scope);
                self.scopes
                    .lock()
                    .map_err(|_| DispatchError::Unavailable)?
                    .remove(&scope.task_id);
                value.unwrap_or(Err(DispatchError::Unavailable))
            }
        }
    }
    async fn execute(
        &self,
        scope: ExecutionScope,
        call_id: Identifier,
        name: String,
        arguments: Value,
    ) -> Result<ToolOutput, DispatchError> {
        let token = {
            let scopes = self.scopes.lock().map_err(|_| DispatchError::Unavailable)?;
            let slot = scopes
                .get(&scope.task_id)
                .filter(|s| s.scope == scope && !s.cancellation.is_cancelled())
                .ok_or(DispatchError::StaleScope)?;
            slot.cancellation.clone()
        };
        let (reply, result) = oneshot::channel();
        self.sender
            .send(NativeCommand::Execute {
                scope,
                call_id,
                name,
                arguments,
                cancellation: token.clone(),
                reply,
            })
            .map_err(|_| DispatchError::Unavailable)?;
        tokio::select! {biased;_ = token.cancelled()=>Err(DispatchError::StaleScope),reply=result=>reply.map_err(|_|DispatchError::Unavailable)?}
    }
    async fn end_turn(&self, scope: ExecutionScope) -> TurnConclusion {
        self.revoke(&scope);
        if let Ok(mut scopes) = self.scopes.lock()
            && scopes.get(&scope.task_id).is_some_and(|s| s.scope == scope)
        {
            scopes.remove(&scope.task_id);
        }
        let (reply, result) = oneshot::channel();
        if self
            .sender
            .send(NativeCommand::End { scope, reply })
            .is_err()
        {
            return TurnConclusion {
                unresolved_operations: 1,
                failed_operations: 0,
            };
        }
        result.await.unwrap_or(TurnConclusion {
            unresolved_operations: 1,
            failed_operations: 0,
        })
    }
}
impl Drop for ChannelToolDispatcher {
    fn drop(&mut self) {
        self.revoke_all();
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use computa_contracts::tools::InteractionPolicy;
    fn scope() -> ExecutionScope {
        ExecutionScope {
            task_id: Identifier::new("task").unwrap(),
            thread_id: Identifier::new("thread").unwrap(),
            turn_id: Identifier::new("turn").unwrap(),
            generation: uuid::Uuid::new_v4(),
            policy: InteractionPolicy::BackgroundOnly,
        }
    }
    #[tokio::test]
    async fn cancellation_is_visible_before_main_thread_end_can_run() {
        let (d, mut commands) = ChannelToolDispatcher::channel();
        let s = scope();
        let begun = {
            let d = d.clone();
            let s = s.clone();
            tokio::spawn(async move { d.begin_turn(s).await })
        };
        let NativeCommand::Begin {
            cancellation,
            reply,
            ..
        } = commands.recv().await.unwrap()
        else {
            panic!("begin")
        };
        reply.send(Ok(())).unwrap();
        begun.await.unwrap().unwrap();
        let execution = {
            let d = d.clone();
            let s = s.clone();
            tokio::spawn(async move {
                d.execute(
                    s,
                    Identifier::new("call").unwrap(),
                    "computer_v2_status".into(),
                    Value::Null,
                )
                .await
            })
        };
        let NativeCommand::Execute {
            cancellation: active,
            ..
        } = commands.recv().await.unwrap()
        else {
            panic!("execute")
        };
        let ending = {
            let d = d.clone();
            let s = s.clone();
            tokio::spawn(async move { d.end_turn(s).await })
        };
        let NativeCommand::End { reply, .. } = commands.recv().await.unwrap() else {
            panic!("end")
        };
        assert!(cancellation.is_cancelled());
        assert!(active.is_cancelled());
        assert!(execution.await.unwrap().is_err());
        reply
            .send(TurnConclusion {
                unresolved_operations: 1,
                failed_operations: 0,
            })
            .unwrap();
        assert_eq!(ending.await.unwrap().unresolved_operations, 1);
        assert!(
            d.execute(
                s,
                Identifier::new("later").unwrap(),
                "computer_v2_status".into(),
                Value::Null
            )
            .await
            .is_err()
        );
    }
    #[tokio::test]
    async fn closed_native_channel_reports_unverified_conclusion() {
        let (d, receiver) = ChannelToolDispatcher::channel();
        drop(receiver);
        assert_eq!(d.end_turn(scope()).await.unresolved_operations, 1);
    }
}
