#!/bin/zsh -f
set -euo pipefail
umask 077

# Run from the mounted release, not the source checkout. No global tools,
# shell-profile edits, privilege escalation, signing, or quarantine removal.
package_dir=${0:A:h}
download_model=0
launch_argument=()
for argument in "$@"; do
  case "$argument" in
    --download-model) download_model=1 ;;
    --no-launch) launch_argument=(--no-launch) ;;
    --help|-h)
      print 'Usage: Install Mactopus.command [--download-model] [--no-launch]'
      print 'Install the signed app, private Python/MLX runtime and pinned Qwen 4B (~3.06 GB).'
      print 'Without --download-model, asks before any download or installation.'
      exit 0 ;;
    *) print -u2 "Unknown option: $argument"; exit 2 ;;
  esac
done
fail() { print -u2 -- "Mactopus installer: $*"; exit 1; }
safe_directory() {
  local candidate=$1
  [[ ${candidate} == /* && ${candidate} != / && ! -L ${candidate} ]] || fail "Unsafe directory: ${candidate}"
  local ancestor=${candidate}
  while [[ ${ancestor} != / ]]; do
    [[ ! -L ${ancestor} ]] || fail "Symlinked installation path: ${ancestor}"
    ancestor=${ancestor:h}
  done
  [[ ! -e ${candidate} || -d ${candidate} ]] || fail "Not a directory: ${candidate}"
}
stopped() {
  local result=0
  /usr/bin/pgrep -x Mactopus >/dev/null && result=0 || result=$?
  [[ ${result} == 1 ]] || fail 'Quit Mactopus normally and leave it closed until installation finishes. No process was stopped.'
}

[[ $(/usr/bin/uname -s) == Darwin && $(/usr/bin/uname -m) == arm64 ]] || fail 'Apple Silicon macOS is required. Run Terminal natively, not under Rosetta.'
[[ -d ${package_dir}/Mactopus.app && ! -L ${package_dir}/Mactopus.app ]] || fail 'Keep this command beside Mactopus.app in the mounted release.'
[[ -f ${package_dir}/SHA256SUMS && ! -L ${package_dir}/SHA256SUMS ]] || fail 'Release checksums are missing.'
(cd "${package_dir}" && /usr/bin/shasum -a 256 --check SHA256SUMS) || fail 'Release files failed checksum verification. Download the release again.'
minimum_os=$(/usr/bin/plutil -extract minimumMacOS raw -o - "${package_dir}/release-manifest.json")
current_os=$(/usr/bin/sw_vers -productVersion)
autoload -Uz is-at-least
is-at-least "${minimum_os}" "${current_os}" || fail "macOS ${minimum_os} or later is required."
/usr/bin/codesign --verify --deep --strict -R '=anchor apple generic' "${package_dir}/Mactopus.app" || fail 'The app signature is invalid.'
[[ $(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "${package_dir}/Mactopus.app/Contents/Info.plist") == com.ahmedelamin.LocalCodex ]] || fail 'Unexpected application identity.'
stopped
if (( ! download_model )); then
  [[ -t 0 ]] || fail 'Use --download-model to explicitly permit the runtime and model downloads.'
  print 'Install Mactopus into ~/Applications and download its private runtime plus Qwen 4B (~3.06 GB)?'
  print 'Allow about 10 GB free space for dependencies, resumable downloads, and model staging.'
  print 'Existing apps are backed up. Conversations, preferences and browser tabs are preserved.'
  read -r 'answer?Type INSTALL to continue: '
  [[ ${answer} == INSTALL ]] || fail 'Cancelled; no download or installation started.'
fi

support_dir="${HOME}/Library/Application Support/LocalCodex"
installer_dir="${support_dir}/Installer"
runtime_dir="${support_dir}/MLX"
for directory in "${support_dir}" "${installer_dir}" "${runtime_dir}" "${runtime_dir}/python" "${runtime_dir}/uv-cache"; do
  safe_directory "${directory}"
done
/bin/mkdir -p "${installer_dir}" "${runtime_dir}/python" "${runtime_dir}/uv-cache"
bootstrap_dir=$(/usr/bin/mktemp -d "${installer_dir}/bootstrap.XXXXXX")
# Failed temporary downloads are intentionally retained for inspection; neither
# this script nor the Python installer recursively deletes an installation.
lock="${package_dir}/Installer/uv.lock.json"
uv_version=$(/usr/bin/plutil -extract version raw -o - "${lock}")
uv_url=$(/usr/bin/plutil -extract url raw -o - "${lock}")
uv_sha=$(/usr/bin/plutil -extract sha256 raw -o - "${lock}")
python_version=$(/usr/bin/plutil -extract pythonVersion raw -o - "${lock}")
[[ ${uv_version} == <->.<->.<-> && ${python_version} == 3.12.13 ]] || fail 'Invalid runtime bootstrap pin.'
[[ ${uv_url} == "https://github.com/astral-sh/uv/releases/download/${uv_version}/uv-aarch64-apple-darwin.tar.gz" ]] || fail 'Unexpected bootstrap origin.'
[[ ${#uv_sha} == 64 && ${uv_sha} != *[^0-9a-f]* ]] || fail 'Invalid bootstrap checksum.'
print "Downloading verified uv ${uv_version} from its pinned official release..."
/usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 30 \
  --output "${bootstrap_dir}/uv.tar.gz" "${uv_url}" || fail 'Bootstrap download failed; rerun the installer to retry.'
print -r -- "${uv_sha}  ${bootstrap_dir}/uv.tar.gz" | /usr/bin/shasum -a 256 --check - || fail 'Bootstrap checksum mismatch; nothing downloaded was executed.'
/usr/bin/tar -xzf "${bootstrap_dir}/uv.tar.gz" -C "${bootstrap_dir}" --strip-components 1 uv-aarch64-apple-darwin/uv
uv_path="${bootstrap_dir}/uv"
[[ -f ${uv_path} && ! -L ${uv_path} && -x ${uv_path} ]] || fail 'Bootstrap executable is missing or unsafe.'

# A fixed environment keeps credentials, mirrors, startup hooks and user uv
# configuration out of the installer; Python and caches stay app-owned.
clean_env=(/usr/bin/env -i "HOME=${HOME}" PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8
  UV_NO_CONFIG=1 UV_PYTHON_INSTALL_BIN=0 "UV_PYTHON_INSTALL_DIR=${runtime_dir}/python"
  "UV_CACHE_DIR=${runtime_dir}/uv-cache")
stopped
"${clean_env[@]}" "${uv_path}" python install --no-bin "${python_version}"
python_path=$("${clean_env[@]}" "${uv_path}" python find --managed-python --no-python-downloads "${python_version}")
[[ ${python_path} == "${runtime_dir}/python/"* && -x ${python_path} ]] || fail 'Managed Python was not installed under the app-owned path.'
"${clean_env[@]}" "${python_path}" -I "${package_dir}/Installer/install-release.py" \
  --package-root "${package_dir}" --uv "${uv_path}" --download-model "${launch_argument[@]}"
