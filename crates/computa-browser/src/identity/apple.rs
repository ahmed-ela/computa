use super::*;
use std::ffi::c_void;
type Ref = *const c_void;
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithCString(allocator: Ref, string: *const i8, encoding: u32) -> Ref;
    fn CFStringGetCString(string: Ref, buffer: *mut i8, size: isize, encoding: u32) -> bool;
    fn CFRelease(value: Ref);
    fn CFNumberCreate(allocator: Ref, kind: isize, value: *const c_void) -> Ref;
    fn CFDictionaryCreate(
        allocator: Ref,
        keys: *const Ref,
        values: *const Ref,
        count: isize,
        key_callbacks: Ref,
        value_callbacks: Ref,
    ) -> Ref;
    fn CFDictionaryGetValue(dictionary: Ref, key: Ref) -> Ref;
    fn CFURLCreateFromFileSystemRepresentation(
        allocator: Ref,
        bytes: *const u8,
        length: isize,
        is_directory: bool,
    ) -> Ref;
    static kCFTypeDictionaryKeyCallBacks: [usize; 6];
    static kCFTypeDictionaryValueCallBacks: [usize; 5];
}
#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SecCodeCopySelf(flags: u32, code: *mut Ref) -> i32;
    fn SecCodeCopyGuestWithAttributes(
        host: Ref,
        attributes: Ref,
        flags: u32,
        code: *mut Ref,
    ) -> i32;
    fn SecCodeCopyStaticCode(code: Ref, flags: u32, static_code: *mut Ref) -> i32;
    fn SecCodeCopySigningInformation(code: Ref, flags: u32, information: *mut Ref) -> i32;
    fn SecRequirementCreateWithString(string: Ref, flags: u32, requirement: *mut Ref) -> i32;
    fn SecCodeCheckValidity(code: Ref, flags: u32, requirement: Ref) -> i32;
    fn SecStaticCodeCreateWithPath(path: Ref, flags: u32, code: *mut Ref) -> i32;
    fn SecStaticCodeCheckValidity(code: Ref, flags: u32, requirement: Ref) -> i32;
    static kSecGuestAttributePid: Ref;
    static kSecCodeInfoIdentifier: Ref;
    static kSecCodeInfoTeamIdentifier: Ref;
}
struct Owned(Ref);
impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: Owned retains exactly one Create/Copy reference.
            unsafe { CFRelease(self.0) };
        }
    }
}
fn string(text: &str) -> Result<Owned, BrowserError> {
    let text = std::ffi::CString::new(text).map_err(|_| BrowserError::Identity)?;
    // SAFETY: CString supplies terminated UTF-8 for the full call.
    let value = unsafe { CFStringCreateWithCString(std::ptr::null(), text.as_ptr(), 0x08000100) };
    if value.is_null() {
        Err(BrowserError::Identity)
    } else {
        Ok(Owned(value))
    }
}
fn read_string(value: Ref) -> Result<String, BrowserError> {
    if value.is_null() {
        return Err(BrowserError::SigningRequired);
    }
    let mut buffer = [0i8; 512];
    // SAFETY: Security signing dictionary provides CFString values; the writable buffer has the passed length.
    if !unsafe {
        CFStringGetCString(
            value,
            buffer.as_mut_ptr(),
            buffer.len() as isize,
            0x08000100,
        )
    } {
        return Err(BrowserError::Identity);
    }
    // SAFETY: the successful CF call writes a terminated string into buffer.
    unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| BrowserError::Identity)
}
fn check(code: Ref, identifier: &str, team: &str) -> Result<(), BrowserError> {
    let rule = string(&apple_requirement(identifier, team)?)?;
    let mut required = std::ptr::null();
    // SAFETY: live string handle and writable retained-handle output.
    if unsafe { SecRequirementCreateWithString(rule.0, 0, &mut required) } != 0 {
        return Err(BrowserError::Identity);
    }
    let required = Owned(required);
    // SAFETY: both arguments are retained Security handles.
    if unsafe { SecCodeCheckValidity(code, 0, required.0) } == 0 {
        Ok(())
    } else {
        Err(BrowserError::Identity)
    }
}
pub(super) fn verify_application() -> Result<(), BrowserError> {
    application_team().map(|_| ())
}
pub(super) fn application_team() -> Result<String, BrowserError> {
    let mut own = std::ptr::null();
    // SAFETY: own is a live writable retained-reference output.
    if unsafe { SecCodeCopySelf(0, &mut own) } != 0 {
        return Err(BrowserError::SigningRequired);
    }
    let own = Owned(own);
    let mut static_code = std::ptr::null();
    // SAFETY: own is retained and static_code is a writable retained-reference output.
    if unsafe { SecCodeCopyStaticCode(own.0, 0, &mut static_code) } != 0 {
        return Err(BrowserError::SigningRequired);
    }
    let static_code = Owned(static_code);
    let mut info = std::ptr::null();
    // SAFETY: the retained static code provides a retained signing dictionary in info.
    if unsafe { SecCodeCopySigningInformation(static_code.0, 2, &mut info) } != 0 {
        return Err(BrowserError::SigningRequired);
    }
    let info = Owned(info);
    // SAFETY: these static Security keys identify CFString values in the signing dictionary.
    let identifier = read_string(unsafe { CFDictionaryGetValue(info.0, kSecCodeInfoIdentifier) })?;
    // SAFETY: same retained signing dictionary and static CFString-valued Security key.
    let team = read_string(unsafe { CFDictionaryGetValue(info.0, kSecCodeInfoTeamIdentifier) })?;
    if identifier != APP_IDENTIFIER {
        return Err(BrowserError::SigningRequired);
    }
    check(own.0, APP_IDENTIFIER, &team).map_err(|_| BrowserError::SigningRequired)?;
    Ok(team)
}
pub(super) fn validate_static(
    path: &Path,
    identifier: &str,
    team: &str,
) -> Result<(), BrowserError> {
    use std::os::unix::ffi::OsStrExt;
    let bytes = path.as_os_str().as_bytes();
    if !path.is_absolute() || bytes.contains(&0) {
        return Err(BrowserError::Identity);
    }
    // SAFETY: bytes is live for the call and CFURL copies exactly its bounded length.
    let url = Owned(unsafe {
        CFURLCreateFromFileSystemRepresentation(
            std::ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
            path.is_dir(),
        )
    });
    if url.0.is_null() {
        return Err(BrowserError::Identity);
    }
    let mut code = std::ptr::null();
    // SAFETY: url is retained and code is a writable retained-reference output.
    if unsafe { SecStaticCodeCreateWithPath(url.0, 0, &mut code) } != 0 {
        return Err(BrowserError::SigningRequired);
    }
    let code = Owned(code);
    let rule = string(&apple_requirement(identifier, team)?)?;
    let mut required = std::ptr::null();
    // SAFETY: rule is retained and required is a writable retained-reference output.
    if unsafe { SecRequirementCreateWithString(rule.0, 0, &mut required) } != 0 {
        return Err(BrowserError::Identity);
    }
    let required = Owned(required);
    // All architectures, nested code and strict resource validation (Security SDK constants).
    // SAFETY: both inputs are retained Security handles; flags are the documented validation options.
    if unsafe { SecStaticCodeCheckValidity(code.0, (1 << 0) | (1 << 3) | (1 << 4), required.0) }
        == 0
    {
        Ok(())
    } else {
        Err(BrowserError::SigningRequired)
    }
}
pub(super) fn validate(
    pid: i32,
    identifier: &str,
    vendor_team: Option<&str>,
) -> Result<(), BrowserError> {
    let team = if let Some(team) = vendor_team {
        if identifier != "com.google.Chrome" || team != "EQHXZ8M8AV" {
            return Err(BrowserError::Identity);
        }
        team.to_owned()
    } else {
        let mut own = std::ptr::null();
        // SAFETY: own is a live output handle.
        if unsafe { SecCodeCopySelf(0, &mut own) } != 0 {
            return Err(BrowserError::SigningRequired);
        }
        let own = Owned(own);
        let mut static_code = std::ptr::null();
        // SAFETY: own is retained and static_code is a writable output.
        if unsafe { SecCodeCopyStaticCode(own.0, 0, &mut static_code) } != 0 {
            return Err(BrowserError::SigningRequired);
        }
        let static_code = Owned(static_code);
        let mut info = std::ptr::null();
        // SAFETY: SigningInformation returns a retained dictionary.
        if unsafe { SecCodeCopySigningInformation(static_code.0, 2, &mut info) } != 0 {
            return Err(BrowserError::SigningRequired);
        }
        let info = Owned(info);
        // SAFETY: Apple signing dictionary maps these static Security keys to CFString values.
        let own_identifier =
            read_string(unsafe { CFDictionaryGetValue(info.0, kSecCodeInfoIdentifier) })?;
        // SAFETY: same retained signing dictionary, static team key.
        let team =
            read_string(unsafe { CFDictionaryGetValue(info.0, kSecCodeInfoTeamIdentifier) })?;
        if !((own_identifier == APP_IDENTIFIER && identifier == HOST_IDENTIFIER)
            || (own_identifier == HOST_IDENTIFIER && identifier == APP_IDENTIFIER))
        {
            return Err(BrowserError::Identity);
        }
        check(own.0, &own_identifier, &team).map_err(|_| BrowserError::SigningRequired)?;
        team
    };
    // SAFETY: CFNumberCreate copies the live signed 32-bit PID.
    let number = Owned(unsafe { CFNumberCreate(std::ptr::null(), 3, (&pid as *const i32).cast()) });
    // SAFETY: arrays have one retained entry and CoreFoundation callbacks/keys are static.
    let attributes = Owned(unsafe {
        CFDictionaryCreate(
            std::ptr::null(),
            [kSecGuestAttributePid].as_ptr(),
            [number.0].as_ptr(),
            1,
            (&kCFTypeDictionaryKeyCallBacks as *const [usize; 6]).cast(),
            (&kCFTypeDictionaryValueCallBacks as *const [usize; 5]).cast(),
        )
    });
    let mut guest = std::ptr::null();
    // SAFETY: attributes is retained, guest is a live nullable output.
    if unsafe { SecCodeCopyGuestWithAttributes(std::ptr::null(), attributes.0, 0, &mut guest) } != 0
    {
        return Err(BrowserError::Identity);
    }
    let guest = Owned(guest);
    check(guest.0, identifier, &team)
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFDataCreate(allocator: Ref, bytes: *const u8, length: isize) -> Ref;
    fn CFDataGetLength(data: Ref) -> isize;
    fn CFDataGetBytePtr(data: Ref) -> *const u8;
    static kCFBooleanTrue: Ref;
}
#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SecItemCopyMatching(query: Ref, result: *mut Ref) -> i32;
    fn SecItemUpdate(query: Ref, attributes: Ref) -> i32;
    fn SecItemAdd(attributes: Ref, result: *mut Ref) -> i32;
    fn SecItemDelete(query: Ref) -> i32;
    static kSecClass: Ref;
    static kSecClassGenericPassword: Ref;
    static kSecAttrService: Ref;
    static kSecAttrAccount: Ref;
    static kSecReturnData: Ref;
    static kSecMatchLimit: Ref;
    static kSecMatchLimitOne: Ref;
    static kSecValueData: Ref;
    static kSecAttrAccessible: Ref;
    static kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: Ref;
    static kSecUseAuthenticationUI: Ref;
    static kSecUseAuthenticationUIFail: Ref;
}
fn dictionary(entries: &[(Ref, Ref)]) -> Owned {
    let keys: Vec<_> = entries.iter().map(|(key, _)| *key).collect();
    let values: Vec<_> = entries.iter().map(|(_, value)| *value).collect();
    // SAFETY: all entries are live CF values; typed callbacks retain them for the dictionary's lifetime.
    Owned(unsafe {
        CFDictionaryCreate(
            std::ptr::null(),
            keys.as_ptr(),
            values.as_ptr(),
            entries.len() as isize,
            (&kCFTypeDictionaryKeyCallBacks as *const [usize; 6]).cast(),
            (&kCFTypeDictionaryValueCallBacks as *const [usize; 5]).cast(),
        )
    })
}
pub(super) fn keychain_load(installation: &str) -> Result<Option<String>, BrowserError> {
    if !computa_contracts::chrome::uuid_text(installation) {
        return Err(BrowserError::Configuration);
    }
    let service = string("com.ahmedelamin.LocalCodex.ChromeBridgePairing.v1")?;
    let account = string(installation)?;
    // SAFETY: Security/CoreFoundation keys and enumerated values are static retained handles.
    let query = unsafe {
        dictionary(&[
            (kSecClass, kSecClassGenericPassword),
            (kSecAttrService, service.0),
            (kSecAttrAccount, account.0),
            (kSecReturnData, kCFBooleanTrue),
            (kSecMatchLimit, kSecMatchLimitOne),
            (kSecUseAuthenticationUI, kSecUseAuthenticationUIFail),
        ])
    };
    let mut data = std::ptr::null();
    // SAFETY: query is a retained dictionary; data is a live writable output.
    let status = unsafe { SecItemCopyMatching(query.0, &mut data) };
    if status == -25300 {
        return Ok(None);
    }
    if status != 0 {
        return Err(BrowserError::Unavailable);
    }
    let data = Owned(data);
    // SAFETY: kSecReturnData requests a retained CFData result, not a reference or attribute dictionary.
    let length = unsafe { CFDataGetLength(data.0) };
    if !(32..=256).contains(&length) {
        return Err(BrowserError::Identity);
    }
    // SAFETY: CFData's buffer remains valid while data is retained, and length is validated positive.
    let bytes = unsafe { std::slice::from_raw_parts(CFDataGetBytePtr(data.0), length as usize) };
    Ok(Some(
        std::str::from_utf8(bytes)
            .map_err(|_| BrowserError::Identity)?
            .to_owned(),
    ))
}
pub(super) fn keychain_save(installation: &str, token: &str) -> Result<(), BrowserError> {
    if !computa_contracts::chrome::uuid_text(installation)
        || !(32..=256).contains(&token.len())
        || token.contains('\0')
    {
        return Err(BrowserError::Configuration);
    }
    let service = string("com.ahmedelamin.LocalCodex.ChromeBridgePairing.v1")?;
    let account = string(installation)?;
    // SAFETY: CFData copies token bytes from a live Rust slice.
    let data =
        Owned(unsafe { CFDataCreate(std::ptr::null(), token.as_ptr(), token.len() as isize) });
    // SAFETY: the Security keys are static and values are retained local CF objects.
    let query = unsafe {
        dictionary(&[
            (kSecClass, kSecClassGenericPassword),
            (kSecAttrService, service.0),
            (kSecAttrAccount, account.0),
        ])
    };
    // SAFETY: same live value and static Security key.
    let update = unsafe { dictionary(&[(kSecValueData, data.0)]) };
    // SAFETY: both arguments are retained dictionaries of Security API attributes.
    let status = unsafe { SecItemUpdate(query.0, update.0) };
    if status == 0 {
        return Ok(());
    }
    if status != -25300 {
        return Err(BrowserError::Configuration);
    }
    // SAFETY: static Security keys and retained data account and service, with device-only accessibility.
    let insert = unsafe {
        dictionary(&[
            (kSecClass, kSecClassGenericPassword),
            (kSecAttrService, service.0),
            (kSecAttrAccount, account.0),
            (kSecValueData, data.0),
            (
                kSecAttrAccessible,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ),
        ])
    };
    // SAFETY: result is intentionally null because only status is needed.
    if unsafe { SecItemAdd(insert.0, std::ptr::null_mut()) } == 0 {
        Ok(())
    } else {
        Err(BrowserError::Configuration)
    }
}
pub(super) fn keychain_forget(installation: &str) -> Result<(), BrowserError> {
    if !computa_contracts::chrome::uuid_text(installation) {
        return Err(BrowserError::Configuration);
    }
    let service = string("com.ahmedelamin.LocalCodex.ChromeBridgePairing.v1")?;
    let account = string(installation)?;
    // SAFETY: static keys and retained query strings.
    let query = unsafe {
        dictionary(&[
            (kSecClass, kSecClassGenericPassword),
            (kSecAttrService, service.0),
            (kSecAttrAccount, account.0),
        ])
    };
    // SAFETY: query is retained throughout deletion.
    match unsafe { SecItemDelete(query.0) } {
        0 | -25300 => Ok(()),
        _ => Err(BrowserError::Configuration),
    }
}
