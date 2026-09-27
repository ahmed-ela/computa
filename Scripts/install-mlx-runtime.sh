#!/bin/zsh
set -euo pipefail

# No global Python packages, model conversions, or visual-grounder downloads.
# LOCALCODEX_MLX_HOME is an explicit developer/test destination override; the
# ordinary app discovers only its standard Application Support destination.
download_model=0
for argument in "$@"; do
  case "$argument" in
    --download-model) download_model=1 ;;
    --help|-h)
      print 'Usage: /bin/zsh Scripts/install-mlx-runtime.sh [--download-model]'
      print 'Installs pinned Python/MLX serving packages under LocalCodex/MLX.'
      print -r -- '--download-model additionally downloads and verifies pinned Qwen 4B (~3.06 GB).'
      exit 0 ;;
    *) print -u2 "Unknown option: $argument"; exit 2 ;;
  esac
done

script_dir=${0:A:h}
runtime_dir=${LOCALCODEX_MLX_HOME:-"${HOME}/Library/Application Support/LocalCodex/MLX"}
python_path=${runtime_dir}/venv/bin/python
uv_path=${LOCALCODEX_UV:-${commands[uv]:-}}
python_version=3.12.13

if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ]]; then
  print -u2 'The pinned MLX runtime requires Apple Silicon macOS.'; exit 1
fi
if [[ -z ${uv_path} || ! -x ${uv_path} ]]; then
  print -u2 'uv is required. Install it first, then rerun this script.'; exit 1
fi
if /usr/bin/pgrep -x Mactopus >/dev/null; then
  print -u2 'Quit Mactopus before changing its inference environment. No process was stopped.'; exit 1
fi
if [[ ${runtime_dir} != /* || ${runtime_dir} == / || ${runtime_dir} == ${HOME} || -L ${runtime_dir} ]]; then
  print -u2 'Refusing an unsafe MLX environment destination.'; exit 1
fi
mkdir -p "${runtime_dir}/models"
chmod 700 "${runtime_dir}" "${runtime_dir}/models"
if [[ -L ${runtime_dir}/venv ]]; then
  print -u2 'Refusing a symlinked MLX environment.'; exit 1
fi
if [[ ! -x ${python_path} ]]; then
  if [[ -e ${runtime_dir}/venv ]]; then
    print -u2 'An incomplete MLX environment exists; it was left untouched.'; exit 1
  fi
  "${uv_path}" venv --python "${python_version}" --managed-python "${runtime_dir}/venv"
fi
actual_python_version=$("${python_path}" -I -c 'import platform; print(platform.python_version())')
if [[ ${actual_python_version} != ${python_version} ]]; then
  print -u2 "Expected Python ${python_version}; existing environment was left untouched."; exit 1
fi
"${uv_path}" pip sync --python "${python_path}" --require-hashes --strict --no-build --no-sources \
  "${script_dir}/mlx-runtime-requirements.lock"
"${uv_path}" pip check --python "${python_path}"
"${python_path}" -I "${script_dir}/mlx-runtime-install.py" verify-runtime \
  --lock "${script_dir}/mlx-runtime-requirements.lock" --receipt "${runtime_dir}/installation.json"

if (( download_model )); then
  HF_HUB_DISABLE_IMPLICIT_TOKEN=1 HF_HUB_DISABLE_TELEMETRY=1 \
    "${python_path}" -I "${script_dir}/mlx-runtime-install.py" install-model \
      --manifest "${script_dir}/mlx-model.lock.json" --model-root "${runtime_dir}/models"
else
  print 'No model weights downloaded. Use --download-model for the pinned Qwen 4B model.'
  print 'Existing supported models in ~/.lmstudio/models remain available without copying.'
fi
print "MLX serving runtime ready: ${runtime_dir}"
