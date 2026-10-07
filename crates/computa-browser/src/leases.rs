use crate::{BrowserError, ChromeLink};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::HashMap, sync::Arc};
use tokio::sync::Mutex;
use uuid::Uuid;
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    #[serde(rename = "targetID")]
    pub target_id: String,
    pub title: String,
    pub url: String,
    pub availability: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub attachment_token: String,
    #[serde(rename = "targetID")]
    pub target_id: String,
    pub title: String,
    pub url: String,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrowserOwnership {
    Borrowed,
    Owned,
}
#[async_trait::async_trait]
pub trait BrowserControl: Send + Sync {
    fn generation(&self) -> Uuid;
    fn bridge_epoch(&self) -> Uuid;
    fn ownership(&self) -> BrowserOwnership;
    async fn inventory(&self) -> Result<Vec<Candidate>, BrowserError>;
    async fn attach(&self, target: &str) -> Result<Attachment, BrowserError>;
    async fn command(
        &self,
        token: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, BrowserError>;
    async fn detach(&self, token: &str) -> Result<(), BrowserError>;
    async fn navigate(&self, _token: &str, _url: &str) -> Result<Value, BrowserError> {
        Err(BrowserError::Rejected("unsupported_command".into()))
    }
    async fn create_temporary(
        &self,
        _task: Uuid,
        _source: &str,
        _url: &str,
    ) -> Result<Value, BrowserError> {
        Err(BrowserError::Rejected(
            "temporary_tabs_not_authorized".into(),
        ))
    }
    async fn release_temporary(&self, _task: Uuid) -> Result<Value, BrowserError> {
        Err(BrowserError::Rejected(
            "temporary_tabs_not_authorized".into(),
        ))
    }
    async fn shutdown(&self) -> Vec<Value>;
}
pub struct BrowserController {
    pub link: Arc<ChromeLink>,
    pub generation: Uuid,
    pub bridge_epoch: Uuid,
    attachments: Mutex<HashMap<String, Attachment>>,
    receipts: Mutex<HashMap<String, Value>>,
    temporary: bool,
}
impl BrowserController {
    pub async fn authorize(
        link: Arc<ChromeLink>,
        installation: &str,
        token: &str,
        generation: Uuid,
        temporary: bool,
    ) -> Result<Arc<Self>, BrowserError> {
        let hello = link.hello().ok_or(BrowserError::Identity)?;
        if hello.installation_id != installation || !hello.paired || hello.suspended {
            return Err(BrowserError::Identity);
        }
        let mut params = json!({"installationId":installation,"pairingToken":token});
        if temporary {
            params["temporaryTabsVersion"] = json!(1);
        }
        let result = link.request("authorizeSession", params, generation).await?;
        if result["generation"] != generation.to_string() {
            return Err(BrowserError::Identity);
        }
        let bridge_epoch = Uuid::parse_str(
            result["bridgeEpoch"]
                .as_str()
                .ok_or(BrowserError::Identity)?,
        )
        .map_err(|_| BrowserError::Identity)?;
        if bridge_epoch.to_string() != hello.bridge_epoch {
            link.close(BrowserError::Identity);
            return Err(BrowserError::Identity);
        }
        Ok(Arc::new(Self {
            link,
            generation,
            bridge_epoch,
            attachments: Mutex::new(HashMap::new()),
            receipts: Mutex::new(HashMap::new()),
            temporary,
        }))
    }
    pub async fn inventory(&self) -> Result<Vec<Candidate>, BrowserError> {
        let result = self
            .link
            .request("inventory", json!({}), self.generation)
            .await?;
        let candidates: Vec<Candidate> = serde_json::from_value(result["candidates"].clone())
            .map_err(|_| BrowserError::InvalidFrame)?;
        let mut ids = std::collections::HashSet::new();
        if candidates.len() > 2048
            || candidates.iter().any(|c| {
                !ids.insert(&c.target_id)
                    || !eligible(&c.url)
                    || !matches!(c.availability.as_str(), "available" | "busy" | "unknown")
            })
        {
            return Err(BrowserError::InvalidFrame);
        }
        Ok(candidates)
    }
    pub async fn attach(&self, target: &str) -> Result<Attachment, BrowserError> {
        let value = self
            .link
            .request("attach", json!({"targetID":target}), self.generation)
            .await?;
        let item: Attachment =
            serde_json::from_value(value).map_err(|_| BrowserError::InvalidFrame)?;
        if item.target_id != target
            || Uuid::parse_str(&item.attachment_token).is_err()
            || !eligible(&item.url)
        {
            self.link.close(BrowserError::InvalidFrame);
            return Err(BrowserError::InvalidFrame);
        }
        self.attachments
            .lock()
            .await
            .insert(item.attachment_token.clone(), item.clone());
        Ok(item)
    }
    pub async fn command(
        &self,
        token: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, BrowserError> {
        self.link.check_attachment(token)?;
        if !self.attachments.lock().await.contains_key(token) {
            return Err(BrowserError::Closed);
        }
        self.link
            .request(
                "command",
                json!({"attachmentToken":token,"method":method,"params":params}),
                self.generation,
            )
            .await
    }
    pub async fn detach(&self, token: &str) -> Result<(), BrowserError> {
        if !self.attachments.lock().await.contains_key(token) {
            return Err(BrowserError::Closed);
        }
        let result = self
            .link
            .request("detach", json!({"attachmentToken":token}), self.generation)
            .await?;
        if result["detached"] != true {
            return Err(BrowserError::InvalidFrame);
        }
        self.attachments.lock().await.remove(token);
        Ok(())
    }
    pub async fn create_temporary(
        &self,
        task: Uuid,
        source: &str,
        url: &str,
    ) -> Result<Value, BrowserError> {
        if !self.temporary {
            return Err(BrowserError::Rejected(
                "temporary_tabs_not_authorized".into(),
            ));
        }
        let value = self
            .link
            .request(
                "createTemporary",
                json!({"taskNonce":task,"sourceTargetID":source,"expectedSourceURL":url}),
                self.generation,
            )
            .await?;
        if value["taskNonce"] != task.to_string()
            || !value["leaseToken"]
                .as_str()
                .is_some_and(computa_contracts::chrome::uuid_text)
            || value["targetID"].as_str().is_none_or(|id| id.is_empty())
            || !value["url"].as_str().is_some_and(eligible)
        {
            self.link.close(BrowserError::InvalidFrame);
            return Err(BrowserError::InvalidFrame);
        }
        self.receipts.lock().await.insert(
            task.to_string(),
            json!({"leaseToken":value["leaseToken"],"taskNonce":task}),
        );
        Ok(value)
    }
    pub async fn release_temporary(&self, task: Uuid) -> Result<Value, BrowserError> {
        let receipt = self
            .receipts
            .lock()
            .await
            .get(&task.to_string())
            .cloned()
            .ok_or(BrowserError::Closed)?;
        let result = self
            .link
            .request("releaseTemporary", receipt, self.generation)
            .await?;
        if result["released"] != true
            || !result["closed"].is_boolean()
            || !result["retained"].is_boolean()
        {
            return Err(BrowserError::InvalidFrame);
        }
        if result["closed"] == true {
            self.receipts.lock().await.remove(&task.to_string());
        }
        Ok(result)
    }
    /// Release only capabilities issued to this generation without closing the
    /// authenticated link. The native coordinator may then admit a new
    /// generation after its runtime submission fence is held.
    pub async fn cleanup_for_reauthorization(&self) -> Vec<Value> {
        let tasks: Vec<_> = self.receipts.lock().await.keys().cloned().collect();
        let mut unresolved = vec![];
        for task in tasks {
            let result = if let Ok(id) = Uuid::parse_str(&task) {
                self.release_temporary(id).await
            } else {
                Err(BrowserError::InvalidFrame)
            };
            match result {
                Ok(result) if result["closed"] == true => {}
                Ok(result) => unresolved.push(json!({"taskNonce":task,"cleanup":result})),
                Err(_) => unresolved
                    .push(json!({"taskNonce":task,"cleanup":{"closed":false,"retained":true}})),
            }
        }
        let attachments: Vec<_> = self.attachments.lock().await.keys().cloned().collect();
        for token in attachments {
            if self.detach(&token).await.is_err() {
                unresolved.push(json!({"attachmentToken":token,"detached":false}));
            }
        }
        unresolved
    }
    pub async fn shutdown(&self) -> Vec<Value> {
        let unresolved = self.cleanup_for_reauthorization().await;
        self.link.close(BrowserError::Closed);
        unresolved
    }
}
fn eligible(raw: &str) -> bool {
    url::Url::parse(raw)
        .is_ok_and(|u| matches!(u.scheme(), "http" | "https") && u.host_str().is_some())
}

#[async_trait::async_trait]
impl BrowserControl for BrowserController {
    fn generation(&self) -> Uuid {
        self.generation
    }
    fn bridge_epoch(&self) -> Uuid {
        self.bridge_epoch
    }
    fn ownership(&self) -> BrowserOwnership {
        BrowserOwnership::Borrowed
    }
    async fn inventory(&self) -> Result<Vec<Candidate>, BrowserError> {
        BrowserController::inventory(self).await
    }
    async fn attach(&self, target: &str) -> Result<Attachment, BrowserError> {
        BrowserController::attach(self, target).await
    }
    async fn command(
        &self,
        token: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, BrowserError> {
        BrowserController::command(self, token, method, params).await
    }
    async fn detach(&self, token: &str) -> Result<(), BrowserError> {
        BrowserController::detach(self, token).await
    }
    async fn create_temporary(
        &self,
        task: Uuid,
        source: &str,
        url: &str,
    ) -> Result<Value, BrowserError> {
        BrowserController::create_temporary(self, task, source, url).await
    }
    async fn release_temporary(&self, task: Uuid) -> Result<Value, BrowserError> {
        BrowserController::release_temporary(self, task).await
    }
    async fn shutdown(&self) -> Vec<Value> {
        BrowserController::shutdown(self).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{PeerVerifier, VerifiedPeer, framing};
    use computa_contracts::chrome::Request;
    use tokio::net::UnixStream;
    struct VerifiedFixture;
    impl PeerVerifier for VerifiedFixture {
        fn verify_host(&self, _: i32) -> Result<VerifiedPeer, BrowserError> {
            Ok(VerifiedPeer {
                helper_pid: 1,
                chrome_pid: 2,
            })
        }
        fn verify_chrome(&self, _: i32) -> Result<(), BrowserError> {
            Ok(())
        }
    }
    fn fixture() -> (BrowserController, UnixStream) {
        let (a, b) = UnixStream::pair().unwrap();
        let link = ChromeLink::from_verified(a, Arc::new(VerifiedFixture)).unwrap();
        (
            BrowserController {
                link,
                generation: Uuid::new_v4(),
                bridge_epoch: Uuid::new_v4(),
                attachments: Mutex::new(HashMap::new()),
                receipts: Mutex::new(HashMap::new()),
                temporary: true,
            },
            b,
        )
    }
    async fn answer(peer: &mut UnixStream, result: Value, error: Option<&str>) -> Request {
        let bytes = framing::read_async(peer).await.unwrap().unwrap();
        let request: Request = serde_json::from_slice(&bytes).unwrap();
        let response = if let Some(code) = error {
            json!({"version":1,"id":request.id,"generation":request.generation,"ok":false,"error":{"code":code,"message":"fixture"}})
        } else {
            json!({"version":1,"id":request.id,"generation":request.generation,"ok":true,"result":result})
        };
        framing::write_async(peer, &serde_json::to_vec(&response).unwrap())
            .await
            .unwrap();
        request
    }
    #[test]
    fn bridge_target_acronyms_match_existing_wire_protocol() {
        let value = json!({"targetID":"exact","title":"Fixture","url":"https://example.test/","availability":"available"});
        let parsed: Candidate = serde_json::from_value(value).unwrap();
        assert_eq!(parsed.target_id, "exact");
        assert_eq!(serde_json::to_value(parsed).unwrap()["targetID"], "exact");
    }
    #[tokio::test]
    async fn failed_and_retained_cleanup_keeps_exact_receipt_for_retry() {
        let (controller, mut peer) = fixture();
        let task = Uuid::new_v4();
        let receipt = json!({"leaseToken":Uuid::new_v4(),"taskNonce":task});
        controller
            .receipts
            .lock()
            .await
            .insert(task.to_string(), receipt.clone());
        let (result, request) = tokio::join!(
            controller.release_temporary(task),
            answer(&mut peer, json!({}), Some("target_busy"))
        );
        assert!(result.is_err());
        assert_eq!(request.params, receipt);
        assert!(
            controller
                .receipts
                .lock()
                .await
                .contains_key(&task.to_string())
        );
        let (result, request) = tokio::join!(
            controller.release_temporary(task),
            answer(
                &mut peer,
                json!({"released":true,"closed":false,"retained":true}),
                None
            )
        );
        assert_eq!(result.unwrap()["retained"], true);
        assert_eq!(request.params, receipt);
        assert!(
            controller
                .receipts
                .lock()
                .await
                .contains_key(&task.to_string())
        );
        let (result, request) = tokio::join!(
            controller.release_temporary(task),
            answer(
                &mut peer,
                json!({"released":true,"closed":true,"retained":false}),
                None
            )
        );
        assert_eq!(result.unwrap()["closed"], true);
        assert_eq!(request.params, receipt);
        assert!(
            !controller
                .receipts
                .lock()
                .await
                .contains_key(&task.to_string())
        );
    }
    #[tokio::test]
    async fn rejected_detach_keeps_exact_attachment_until_confirmed() {
        let (controller, mut peer) = fixture();
        let token = Uuid::new_v4().to_string();
        controller.attachments.lock().await.insert(
            token.clone(),
            Attachment {
                attachment_token: token.clone(),
                target_id: "exact-target".into(),
                title: String::new(),
                url: "https://example.test/".into(),
            },
        );
        let (result, request) = tokio::join!(
            controller.detach(&token),
            answer(&mut peer, json!({}), Some("target_busy"))
        );
        assert!(result.is_err());
        assert_eq!(request.params["attachmentToken"], token);
        assert!(controller.attachments.lock().await.contains_key(&token));
        let (result, request) = tokio::join!(
            controller.detach(&token),
            answer(&mut peer, json!({"detached":true}), None)
        );
        assert!(result.is_ok());
        assert_eq!(request.params["attachmentToken"], token);
        assert!(!controller.attachments.lock().await.contains_key(&token));
    }
}
