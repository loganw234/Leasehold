#!/usr/bin/env bash
# Creates, or refreshes, the operator account that AI assistants use on this machine:
#   - it logs in over SSH with the given public key only; its password stays locked;
#   - it runs sudo without a password (/etc/sudoers.d/<account>, checked with visudo first);
#   - it joins the GPU groups (render, video) and the USB board groups (dialout, plugdev) that exist.
# Safe to run again: it adds the key once and rewrites the same sudo rule.
#
# leasehold.ps1 grant uploads and runs this with sudo; leasehold.ps1 revoke removes the account
# and the rule.
#
# Usage: sudo bash grant-operator.sh <account> '<ssh public key>'
set -euo pipefail

OP=${1:?usage: grant-operator.sh <account> '<ssh public key>'}
KEY=${2:?usage: grant-operator.sh <account> '<ssh public key>'}

[[ ${EUID} -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
[[ "$OP" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Not a usable account name: $OP" >&2; exit 1; }
key_re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) [A-Za-z0-9+/=]+( .*)?$'
if [[ ! "$KEY" =~ $key_re || "$KEY" == *"'"* || "$KEY" == *'"'* ]]; then
  echo "Not a single SSH public key." >&2
  exit 1
fi

if ! id "$OP" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --comment "Leasehold operator for AI assistants" "$OP"
  echo "Created the $OP account."
fi
passwd -l "$OP" >/dev/null 2>&1

for g in render video dialout plugdev; do
  if getent group "$g" >/dev/null; then usermod -aG "$g" "$OP"; fi
done

home=$(getent passwd "$OP" | cut -d: -f6)
install -d -m 700 -o "$OP" -g "$OP" "$home/.ssh"
keys="$home/.ssh/authorized_keys"
touch "$keys"
chown "$OP:$OP" "$keys"
chmod 600 "$keys"
grep -qxF "$KEY" "$keys" || echo "$KEY" >>"$keys"

rule="/etc/sudoers.d/$OP"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$OP" >"$rule.tmp"
chmod 440 "$rule.tmp"
if ! visudo -cf "$rule.tmp" >/dev/null; then
  rm -f "$rule.tmp"
  echo "visudo rejected the sudo rule; nothing changed in sudoers." >&2
  exit 1
fi
mv "$rule.tmp" "$rule"

echo "Granted: $OP logs in with that key only and runs sudo without a password."
