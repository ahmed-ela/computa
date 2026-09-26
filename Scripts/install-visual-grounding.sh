#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
runtime_dir=${LOCALCODEX_GROUNDER_HOME:-"${HOME}/Library/Application Support/LocalCodex/VisualGrounding"}
model_dir=${runtime_dir}/models
venv_dir=${runtime_dir}/venv
python_path=${runtime_dir}/venv/bin/python
uv_path=${LOCALCODEX_UV:-${commands[uv]:-}}
metadata_script=${script_dir}/visual-grounding-install-metadata.py
model_manifest=${project_dir}/Sources/Macrouse/Resources/VisualGrounding/model-manifest.json
runtime_manifest=${project_dir}/Sources/Macrouse/Resources/VisualGrounding/runtime-manifest.json
requirements_lock=${script_dir}/visual-grounding-requirements.lock
python_version=3.12.13

if [[ -z ${uv_path} || ! -x ${uv_path} ]]; then
  print -u2 "uv is required. Install it first, then rerun this script."
  exit 1
fi

for required_file in ${metadata_script} ${model_manifest} ${runtime_manifest} ${requirements_lock}; do
  if [[ ! -f ${required_file} ]]; then
    print -u2 "Required visual-grounding installation file is missing: ${required_file}"
    exit 1
  fi
done

mkdir -p ${runtime_dir} ${runtime_dir}/Requests
chmod 700 ${runtime_dir} ${runtime_dir}/Requests

if [[ ! -x ${python_path} ]]; then
  if [[ -e ${venv_dir} ]]; then
    print -u2 "Refusing to replace an incomplete visual-grounding environment: ${venv_dir}"
    exit 1
  fi
  ${uv_path} venv --python ${python_version} --managed-python ${venv_dir}
fi
actual_python_version=$("${python_path}" -c 'import platform; print(platform.python_version())')
if [[ ${actual_python_version} != ${python_version} ]]; then
  print -u2 "Refusing visual-grounding Python ${actual_python_version}; expected exactly ${python_version}"
  exit 1
fi
${uv_path} pip sync --python ${python_path} --require-hashes --strict \
  --no-build --no-sources ${requirements_lock}

if [[ -d ${model_dir} ]]; then
  "${python_path}" "${metadata_script}" existing \
    --model-root "${model_dir}" \
    --receipt "${runtime_dir}/installation.json" \
    --manifest "${model_manifest}" \
    --runtime-manifest "${runtime_manifest}"
  chmod 700 "${model_dir}"
  print "Verified the existing pinned visual-grounding installation under ${runtime_dir}"
  exit 0
fi
if [[ -e ${runtime_dir}/installation.json ]]; then
  print -u2 "Refusing an installation receipt without its model directory: ${runtime_dir}/installation.json"
  exit 1
fi

stage_dir=$(mktemp -d "${runtime_dir}/.install.XXXXXX")
stage_models=${stage_dir}/models
mkdir -p ${stage_models}
chmod 700 ${stage_dir} ${stage_models}
cleanup_stage() {
  if [[ -n ${stage_dir:-} && ${stage_dir} == ${runtime_dir}/.install.* ]]; then
    rm -rf -- "${stage_dir}"
  fi
}
trap cleanup_stage EXIT

"${python_path}" -m mlx_vlm convert \
    --hf-path HongxinLi/GoClick-Base \
    --revision 05633a495f9d2ce823372d0c7fd9b0b4bb67c6fa \
    --mlx-path "${stage_models}/goclick-base-4bit" \
    -q --q-bits 4 --q-group-size 64 --q-mode affine --dtype bfloat16 \
    --trust-remote-code

"${python_path}" - "${stage_models}/showui-2b-4bit" <<'PY'
from huggingface_hub import snapshot_download
from pathlib import Path
import sys

snapshot_download(
    repo_id="mlx-community/ShowUI-2B-bf16-4bit",
    revision="c80dc363dfd4e802ef21fe7fd50a0fab8694c59e",
    local_dir=Path(sys.argv[1]),
)
PY

"${python_path}" -m mlx_vlm convert \
    --hf-path mPLUG/GUI-Owl-1.5-2B-Instruct \
    --revision 528ceaec795bbfbe6103bd79e03db849feadfb24 \
    --mlx-path "${stage_models}/gui-owl-2b" \
    -q --q-bits 4 --q-group-size 64 --q-mode affine --dtype bfloat16

"${python_path}" "${metadata_script}" fresh \
  --model-root "${stage_models}" \
  --receipt "${stage_dir}/installation.json" \
  --manifest "${model_manifest}" \
  --runtime-manifest "${runtime_manifest}"
mv "${stage_models}" "${model_dir}"
mv "${stage_dir}/installation.json" "${runtime_dir}/installation.json"
chmod 700 "${model_dir}"
trap - EXIT
rmdir "${stage_dir}"

print "Visual grounding installed under ${runtime_dir}"
print "Worker source: ${project_dir}/Sources/Macrouse/Resources/VisualGrounding/worker.py"
