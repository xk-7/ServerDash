#!/bin/bash
set -euo pipefail

fixture_dir=$(/usr/bin/mktemp -d /tmp/serverdash-s11.XXXXXX)
declare -a sshd_pids=()

cleanup() {
  for pid in "${sshd_pids[@]:-}"; do
    if /bin/kill -0 "$pid" 2>/dev/null; then
      /bin/kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ "$fixture_dir" == /tmp/serverdash-s11.* ]]; then
    /bin/rm -rf "$fixture_dir"
  fi
}
trap cleanup EXIT INT TERM

fixture_user=$(/usr/bin/id -un)
base_port=$((43000 + ($$ % 500) * 3))

port_is_free() {
  ! /usr/bin/nc -z 127.0.0.1 "$1" >/dev/null 2>&1
}

while ! port_is_free "$base_port" ||
      ! port_is_free "$((base_port + 1))" ||
      ! port_is_free "$((base_port + 2))"; do
  base_port=$((base_port + 3))
  if ((base_port > 65000)); then
    echo "Unable to reserve three local fixture ports." >&2
    exit 1
  fi
done

for index in 1 2 3; do
  /usr/bin/ssh-keygen -q -t ed25519 -N '' \
    -f "$fixture_dir/client-$index" < /dev/null
  /usr/bin/ssh-keygen -q -t ed25519 -N '' \
    -f "$fixture_dir/host-$index" < /dev/null
  /bin/cp "$fixture_dir/client-$index.pub" "$fixture_dir/authorized-$index"

  port=$((base_port + index - 1))
  config="$fixture_dir/sshd-$index.conf"
  {
    echo "Port $port"
    echo "ListenAddress 127.0.0.1"
    echo "HostKey $fixture_dir/host-$index"
    echo "PidFile $fixture_dir/sshd-$index.pid"
    echo "AuthorizedKeysFile $fixture_dir/authorized-$index"
    echo "AllowUsers $fixture_user"
    echo "AuthenticationMethods publickey"
    echo "PubkeyAuthentication yes"
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
    echo "UsePAM no"
    echo "StrictModes no"
    echo "PermitRootLogin no"
    echo "PermitUserEnvironment no"
    echo "LogLevel ERROR"
  } > "$config"

  /usr/sbin/sshd -t -f "$config"
  /usr/sbin/sshd -D -e -f "$config" \
    > "$fixture_dir/sshd-$index.log" 2>&1 &
  sshd_pids+=("$!")
done

for port in "$base_port" "$((base_port + 1))" "$((base_port + 2))"; do
  for _ in {1..100}; do
    if /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
      break
    fi
    /bin/sleep 0.02
  done
  if ! /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    echo "Temporary sshd did not become ready on port $port." >&2
    /usr/bin/tail -20 "$fixture_dir/sshd-$((port - base_port + 1)).log" >&2 || true
    exit 1
  fi
  /usr/bin/ssh-keyscan -T 2 -p "$port" 127.0.0.1 \
    >> "$fixture_dir/known_hosts" 2>/dev/null
done

ssh_config="$fixture_dir/ssh_config"
{
  echo "Host *"
  echo "    BatchMode yes"
  echo "    StrictHostKeyChecking yes"
  echo "    UserKnownHostsFile $fixture_dir/known_hosts"
  echo "    GlobalKnownHostsFile /dev/null"
  echo "    IdentitiesOnly yes"
  echo "    ForwardAgent no"
  for index in 1 2 3; do
    port=$((base_port + index - 1))
    alias="hop$index"
    if ((index == 3)); then alias="target"; fi
    echo "Host $alias"
    echo "    HostName 127.0.0.1"
    echo "    Port $port"
    echo "    User $fixture_user"
    echo "    IdentityFile $fixture_dir/client-$index"
  done
  echo "    ProxyJump hop1,hop2"
} > "$ssh_config"

result=$(/usr/bin/ssh -F "$ssh_config" target /usr/bin/printf serverdash-s11-ok)
[[ "$result" == "serverdash-s11-ok" ]]

for index in 1 2 3; do
  /usr/bin/ssh-keygen -lf "$fixture_dir/host-$index.pub"
done
echo "S11 isolated three-hop OpenSSH fixture passed."
