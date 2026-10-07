//! Canonical Apple app versions shared by source builds and release metadata.
use crate::{distribution::invalid, models::read_regular};
use std::{io, path::Path};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppVersion {
    pub marketing: String,
    pub build: String,
}

/// Release tags may carry valid SemVer prerelease/build identifiers. Apple
/// marketing versions remain only the three bounded numeric components.
pub fn release_base(value: &str) -> io::Result<String> {
    let version = semver::Version::parse(value).map_err(|_| invalid("Invalid release SemVer"))?;
    if [version.major, version.minor, version.patch]
        .into_iter()
        .any(|component| component > u64::from(u32::MAX))
    {
        return Err(invalid("Version components exceed u32::MAX"));
    }
    Ok(format!(
        "{}.{}.{}",
        version.major, version.minor, version.patch
    ))
}

pub fn validate_marketing(value: &str) -> io::Result<()> {
    if release_base(value)? != value {
        return Err(invalid(
            "Marketing version must be exactly MAJOR.MINOR.PATCH",
        ));
    }
    Ok(())
}

pub fn validate_build(value: &str) -> io::Result<()> {
    if value.is_empty()
        || value.starts_with('0')
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || value
            .parse::<u16>()
            .ok()
            .is_none_or(|build| !(1..=9999).contains(&build))
    {
        return Err(invalid(
            "Apple build must be a canonical integer from 1 through 9999",
        ));
    }
    Ok(())
}

pub fn validate_release_metadata(
    release: &str,
    marketing: &str,
    build: Option<&str>,
) -> io::Result<()> {
    validate_marketing(marketing)?;
    if release_base(release)? != marketing {
        return Err(invalid(
            "Release tag base does not match the app marketing version",
        ));
    }
    if let Some(build) = build {
        validate_build(build)?;
    }
    Ok(())
}

pub fn parse_xcconfig(source: &str) -> io::Result<AppVersion> {
    let mut marketing = None;
    let mut build = None;
    for line in source.lines() {
        let line = line
            .split_once("//")
            .map_or(line, |(value, _)| value)
            .trim();
        if line.is_empty() {
            continue;
        }
        let (key, value) = line
            .split_once('=')
            .ok_or_else(|| invalid("Unexpected canonical version setting"))?;
        let target = match key.trim() {
            "MARKETING_VERSION" => &mut marketing,
            "CURRENT_PROJECT_VERSION" => &mut build,
            _ => return Err(invalid("Unexpected canonical version setting")),
        };
        if target.replace(value.trim().to_owned()).is_some() {
            return Err(invalid("Duplicate canonical version setting"));
        }
    }
    let marketing = marketing.ok_or_else(|| invalid("Missing MARKETING_VERSION"))?;
    let build = build.ok_or_else(|| invalid("Missing CURRENT_PROJECT_VERSION"))?;
    validate_marketing(&marketing)?;
    validate_build(&build)?;
    Ok(AppVersion { marketing, build })
}

fn workspace_version(source: &str) -> io::Result<&str> {
    let mut in_package = false;
    let mut version = None;
    for line in source.lines() {
        let line = line.split_once('#').map_or(line, |(value, _)| value).trim();
        if line.starts_with('[') {
            in_package = line == "[workspace.package]";
            continue;
        }
        if !in_package {
            continue;
        }
        if let Some((key, value)) = line.split_once('=')
            && key.trim() == "version"
        {
            let value = value.trim();
            let quote = value
                .chars()
                .next()
                .filter(|quote| matches!(quote, '\'' | '"'))
                .ok_or_else(|| invalid("Workspace version must be a quoted numeric literal"))?;
            let value = value
                .strip_prefix(quote)
                .and_then(|value| value.strip_suffix(quote))
                .ok_or_else(|| invalid("Workspace version must use matching quotes"))?;
            if version.replace(value).is_some() {
                return Err(invalid("Duplicate workspace version"));
            }
        }
    }
    version.ok_or_else(|| invalid("Missing workspace.package.version"))
}

fn read_for_compiled(root: &Path, compiled: &str) -> io::Result<AppVersion> {
    let bytes = read_regular(&root.join("Config/Version.xcconfig"), 16 * 1024)?;
    let version = parse_xcconfig(std::str::from_utf8(&bytes).map_err(invalid)?)?;
    let cargo = read_regular(&root.join("Cargo.toml"), 128 * 1024)?;
    if workspace_version(std::str::from_utf8(&cargo).map_err(invalid)?)? != version.marketing
        || compiled != version.marketing
    {
        return Err(invalid(
            "Canonical, workspace and compiled app versions differ; synchronize versions and rebuild the Rust installer",
        ));
    }
    Ok(version)
}

pub fn read(root: &Path) -> io::Result<AppVersion> {
    read_for_compiled(root, env!("CARGO_PKG_VERSION"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn marketing_is_three_canonical_bounded_numbers() {
        for version in ["0.1.1", "1.20.300", "4294967295.0.0"] {
            validate_marketing(version).unwrap();
        }
        for version in [
            "1",
            "1.2",
            "1.2.3.4",
            "01.2.3",
            "1.02.3",
            "1.2.03",
            "1.2.3-beta.1",
            "1.2.3+build",
            "4294967296.0.0",
            " 1.2.3",
            "1.2.3\n",
            "１.2.3",
        ] {
            assert!(validate_marketing(version).is_err(), "{version:?}");
        }
    }

    #[test]
    fn release_identifiers_use_actual_semver_and_match_marketing() {
        for release in ["1.2.3", "1.2.3-preview.1", "1.2.3-preview.1+sha.01"] {
            validate_release_metadata(release, "1.2.3", Some("2")).unwrap();
        }
        for release in [
            "1.2.3-",
            "1.2.3+",
            "1.2.3-a..b",
            "1.2.3-01",
            "1.2.3+build+again",
            "1.2.3.4",
            "1.2.3/unsafe",
        ] {
            assert!(release_base(release).is_err(), "{release}");
        }
        assert!(validate_release_metadata("2.0.0", "1.2.3", Some("2")).is_err());
    }

    #[test]
    fn apple_build_is_positive_canonical_and_bounded() {
        for build in ["1", "2", "9999"] {
            validate_build(build).unwrap();
        }
        for build in ["0", "01", "10000", "1.2", "-1", "+1", " 1", "1\n", "１"] {
            assert!(validate_build(build).is_err(), "{build:?}");
        }
    }

    #[test]
    fn config_rejects_duplicates_missing_keys_and_substitutions() {
        assert_eq!(
            parse_xcconfig("// version\nMARKETING_VERSION = 0.1.1\nCURRENT_PROJECT_VERSION = 2\n")
                .unwrap(),
            AppVersion {
                marketing: "0.1.1".into(),
                build: "2".into()
            }
        );
        for source in [
            "MARKETING_VERSION = 0.1.1",
            "MARKETING_VERSION = 0.1.1\nCURRENT_PROJECT_VERSION = 2\nMARKETING_VERSION = 0.1.1",
            "MARKETING_VERSION = $(VERSION)\nCURRENT_PROJECT_VERSION = 2",
            "MARKETING_VERSION = 0.1.1\nCURRENT_PROJECT_VERSION = 2\nOTHER = 1",
        ] {
            assert!(parse_xcconfig(source).is_err());
        }
    }

    #[test]
    fn doctor_reads_source_and_rejects_workspace_or_compiled_drift() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join("Config")).unwrap();
        fs::write(
            root.path().join("Config/Version.xcconfig"),
            "MARKETING_VERSION = 0.1.1\nCURRENT_PROJECT_VERSION = 2\n",
        )
        .unwrap();
        fs::write(
            root.path().join("Cargo.toml"),
            "[workspace.package]\nversion = \"0.1.1\"\n",
        )
        .unwrap();
        assert_eq!(read_for_compiled(root.path(), "0.1.1").unwrap().build, "2");
        fs::write(
            root.path().join("Cargo.toml"),
            "[workspace.package]\nversion = '0.1.1'\n",
        )
        .unwrap();
        assert!(read_for_compiled(root.path(), "0.1.1").is_ok());
        fs::write(
            root.path().join("Cargo.toml"),
            "[workspace.package]\nversion = '0.1.1\"\n",
        )
        .unwrap();
        assert!(read_for_compiled(root.path(), "0.1.1").is_err());
        fs::write(
            root.path().join("Cargo.toml"),
            "[workspace.package]\nversion = \"0.1.1\"\n",
        )
        .unwrap();
        assert!(read_for_compiled(root.path(), "0.1.0").is_err());
        fs::write(
            root.path().join("Cargo.toml"),
            "[workspace.package]\nversion = \"0.1.0\"\n",
        )
        .unwrap();
        assert!(read_for_compiled(root.path(), "0.1.1").is_err());
    }
}
