#!/bin/zsh
set -euo pipefail

USER_HOME="${HOME}"
MODELS_DIR="${USER_HOME}/Library/Application Support/Softspoke/Models"
BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

mkdir -p "${MODELS_DIR}"

download_model() {
  local filename="$1"
  local checksum="$2"
  local destination="${MODELS_DIR}/${filename}"
  local temporary

  if [[ -f "${destination}" ]] && [[ "$(shasum -a 256 "${destination}" | awk '{print $1}')" == "${checksum}" ]]; then
    echo "Already installed: ${filename}"
    return
  fi

  temporary="${destination}.download"
  echo "Downloading ${filename}..."
  curl --fail --location --progress-bar "${BASE_URL}/${filename}" --output "${temporary}"
  if [[ "$(shasum -a 256 "${temporary}" | awk '{print $1}')" != "${checksum}" ]]; then
    echo "Checksum verification failed for ${filename}" >&2
    rm -f "${temporary}"
    exit 1
  fi
  mv "${temporary}" "${destination}"
  echo "Installed: ${destination}"
}

download_model "ggml-base-q5_1.bin" "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
download_model "ggml-large-v3-turbo-q5_0.bin" "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"

echo "Whisper models are ready."
