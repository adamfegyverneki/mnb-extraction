#!/bin/bash
# Add project-local CLI tools to PATH (AWS CLI, Atlas, Node) when system installs are missing.
# Safe to source from bash or zsh:  source scripts/local-tools-path.sh

if [ -n "${BASH_VERSION:-}" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
  _local_tools_script="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  # zsh: %x = path of the file being sourced
  _local_tools_script="${(%):-%x}"
else
  _local_tools_script="$0"
fi

_local_tools_root="$(cd "$(dirname "${_local_tools_script}")/.." && pwd)/.tools"
if [ -d "${_local_tools_root}" ]; then
  export PATH="${_local_tools_root}/bin:${_local_tools_root}/node-v20.19.2-darwin-arm64/bin:${PATH}"
fi
unset _local_tools_script _local_tools_root
