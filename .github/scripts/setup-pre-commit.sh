#!/usr/bin/env bash

set -euo pipefail

: "${USE_PIPX:=true}"

if ! [[ $PATH =~ (^|:)"${HOME}/.local/bin"(:|$) ]]; then
  # shellcheck disable=SC2088
  echo '~/.local/bin is not on PATH; aborting...'
  exit 1
fi

npm install -g markdownlint-cli@0.37.0
npm install -g prettier@3.0.2

pip_cmd=pip3
if [ "$USE_PIPX" == true ]; then
  pip3 install --user pipx
  pip_cmd=pipx
fi

$pip_cmd install 'pre-commit==3.3.3'
$pip_cmd install 'yamllint==1.32.0'

# ShellCheck
if ! command -v shellcheck; then

  arch=$(uname -m)
  shellcheck_base=https://github.com/koalaman/shellcheck/releases/download
  shellcheck_version=v0.9.0

  wget -nv -O- \
    "${shellcheck_base}/${shellcheck_version}/shellcheck-${shellcheck_version}.linux.${arch}.tar.xz" |
    tar -xJv
  mv "shellcheck-${shellcheck_version}/shellcheck" ~/.local/bin
  rm -rf "shellcheck-${shellcheck_version}"

  command -v shellcheck

fi

# hadolint
if ! command -v hadolint; then

  arch=$(uname -m)
  hadolint_base=https://github.com/hadolint/hadolint/releases/download
  hadolint_version=v2.12.0

  wget -nv -O ~/.local/bin/hadolint \
    "${hadolint_base}/${hadolint_version}/hadolint-Linux-${arch}"
  chmod +x ~/.local/bin/hadolint

  command -v hadolint

fi

# shfmt
if ! command -v shfmt; then
  go install mvdan.cc/sh/v3/cmd/shfmt@v3.7.0
fi
