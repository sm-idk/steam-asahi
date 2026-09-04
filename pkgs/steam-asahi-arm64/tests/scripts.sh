#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2034
#
# Portable behavioral tests for the architecture-independent shell scripts.

set -o errexit
set -o nounset
set -o pipefail

REPOSITORY_ROOT=${1:-$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.."
  pwd -P
)}
readonly REPOSITORY_ROOT
readonly PACKAGE_ROOT="${REPOSITORY_ROOT}/pkgs/steam-asahi-arm64"
TEST_BASH=$(command -v bash)
readonly TEST_BASH
TEST_ROOT=$(mktemp -d)
readonly TEST_ROOT
TEST_SH=$(command -v sh)
readonly TEST_SH
readonly FORCE_PROTON_APP_ID=250900
readonly TEST_APP_ID=12345
readonly TEST_GUEST_COMMAND_EXIT_STATUS=23
readonly TEST_PROTON_RUNNER_EXIT_STATUS=29
readonly TEST_PROTON_RUNTIME_EXIT_STATUS=31
readonly TEST_STEAM_RESTART_EXIT_STATUS=42
export \
  TEST_GUEST_COMMAND_EXIT_STATUS \
  TEST_PROTON_RUNNER_EXIT_STATUS \
  TEST_PROTON_RUNTIME_EXIT_STATUS \
  TEST_STEAM_RESTART_EXIT_STATUS

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local actual=$2
  local expected=$1
  local message=$3

  [[ ${actual} == "${expected}" ]] ||
    fail "${message}: expected <${expected}>, got <${actual}>"
}

assert_file_contains_line() {
  local expected=$2
  local path=$1

  grep -Fqx -- "${expected}" "${path}" ||
    fail "${path} does not contain line <${expected}>"
}

assert_file_lines() {
  local description=$2
  local expected
  local index=0
  local path=$1
  local -a actual_lines

  shift 2
  mapfile -t actual_lines <"${path}"
  assert_equal "$#" "${#actual_lines[@]}" "${description} count"
  for expected in "$@"; do
    assert_equal \
      "${expected}" "${actual_lines[${index}]}" \
      "${description} item ${index}"
    index=$(( index + 1 ))
  done
}

run_expect_status() {
  local expected_status=$1
  local status

  shift
  if "$@"; then
    status=0
  else
    status=$?
  fi
  assert_equal "${expected_status}" "${status}" "unexpected exit status from $*"
}

test_sourceability() {
  (
    NATIVE_LIBRARY_PATH=/native
    # shellcheck source=../scripts/guest.sh
    source "${PACKAGE_ROOT}/scripts/guest.sh"
    declare -F main >/dev/null
  )

  (
    local command_root="${TEST_ROOT}/init-commands"
    local fhs_root="${TEST_ROOT}/init-fhs"

    mkdir -p -- \
      "${command_root}/coreutils" \
      "${command_root}/extra" \
      "${command_root}/glibc" \
      "${fhs_root}/bin" \
      "${fhs_root}/usr/bin"
    touch -- \
      "${command_root}/coreutils/core-command" \
      "${command_root}/extra/extra-command" \
      "${command_root}/glibc/glibc-command"
    BASH_BIN=/bin/bash
    COREUTILS_BIN="${command_root}/coreutils"
    EXTRA_COMMAND_DIRS=("${command_root}/extra")
    ETC_STUB_DIRS=()
    ETC_STUB_FILES=()
    ETC_SYMLINKS_TO_MATERIALIZE=()
    GETOPT=/bin/true
    GLIBC_BIN="${command_root}/glibc"
    GLIBC_I18N=/tmp
    LD_LINUX=/tmp/ld-linux
    LDCONFIG=/bin/true
    LSB_RELEASE=/bin/true
    LSOF=/bin/true
    LSPCI=/bin/true
    NATIVE_RUNTIME=/tmp
    SH_BIN=/bin/sh
    TASKSET=/bin/true
    TZDATA_ZONEINFO=/tmp
    X11_LOCALE=/tmp
    XDG_OPEN=/bin/true
    XDG_USER_DIR=/bin/true
    ZENITY=/bin/true
    # shellcheck source=../scripts/init.sh
    source "${PACKAGE_ROOT}/scripts/init.sh"
    declare -F link_commands >/dev/null
    declare -F install_fhs_commands >/dev/null
    declare -F materialize_etc_symlink >/dev/null
    install_fhs_commands "${fhs_root}"
    assert_equal /bin/true "$(readlink -- "${fhs_root}/bin/getopt")" \
      'getopt FHS link'
    assert_equal /bin/true "$(readlink -- "${fhs_root}/usr/bin/getopt")" \
      'getopt usr FHS link'
    assert_equal /bin/true "$(readlink -- "${fhs_root}/bin/taskset")" \
      'taskset FHS link'
    assert_equal /bin/true "$(readlink -- "${fhs_root}/bin/lsof")" \
      'lsof FHS link'
    assert_equal /bin/true "$(readlink -- "${fhs_root}/usr/bin/xdg-open")" \
      'xdg-open FHS link'
    assert_equal /bin/true "$(readlink -- "${fhs_root}/usr/bin/xdg-user-dir")" \
      'xdg-user-dir FHS link'
    [[ -L ${fhs_root}/bin/core-command ]] \
      || fail 'coreutils command was not linked'
    [[ -L ${fhs_root}/usr/bin/extra-command ]] \
      || fail 'extra command was not linked'
    [[ -L ${fhs_root}/usr/bin/glibc-command ]] \
      || fail 'glibc command was not linked'
  )

  (
    CLIENT_BOOTSTRAP=/tmp
    CLIENT_UPDATE_CHANNEL=publicbeta
    COMPATIBILITY_TOOL_DIRECTORY=compat
    COMPATIBILITY_TOOL_VDF=/tmp/vdf
    CUSTOM_STEAM_HOME_DIR=
    DEFAULT_STEAM_HOME_DIR=steam-asahi-arm64-home
    DISPLAY_NAME=Proton
    ENV_BIN=/usr/bin/env
    FLOCK="$(command -v flock)"
    GUEST_LAUNCHER=/bin/true
    HOST_LIBRARIES=/tmp
    INIT_SCRIPT=/bin/true
    MEMORY_ARGS=()
    MUVM=/bin/true
    NETWORK_ARGS=()
    PROTON_DIRECTORY=proton
    PROTON_CONFIGURATOR=/bin/true
    PROTON_RUNNER=/bin/true
    PROTON_TOOL_NAME=proton-test
    PROTON_WRAPPER=/bin/true
    RUNTIME_APP_ID=1
    RUNTIME_DIRECTORY=runtime
    TOOL_MANIFEST=/tmp/manifest
    VRAM_ARGS=()
    YAD=/bin/true
    HOME="${TEST_ROOT}/source home"
    local source_home="${HOME}"
    # shellcheck source=../scripts/launcher.sh
    source "${PACKAGE_ROOT}/scripts/launcher.sh"
    assert_equal "${source_home}" "${HOME}" 'sourcing launcher changed HOME'
    declare -F import_login_state >/dev/null
    declare -F initialize_steam_home >/dev/null
    declare -F install_managed_file >/dev/null
    declare -F run_with_steam_lock >/dev/null
    declare -F sync_pulse_cookie >/dev/null
    declare -F write_managed_value >/dev/null
  )

  (
    # shellcheck source=../scripts/lspci.sh
    source "${PACKAGE_ROOT}/scripts/lspci.sh"
    declare -F main >/dev/null
  )
}

test_guest_launcher() {
  local expected_data_directories
  local expected_library_path
  local guest_home="${TEST_ROOT}/guest-home"
  local guest_root="${TEST_ROOT}/guest"
  local runtime_tools="${guest_root}/data home/Steam/steamapps/common/\
SteamLinuxRuntime_4-arm64/pressure-vessel/bin"
  local output="${guest_root}/output"
  local status_file="${guest_root}/attempts"

  mkdir -p -- \
    "${guest_home}/.steam" \
    "${guest_root}/data home" \
    "${output}" \
    "${runtime_tools}"
  touch -- "${runtime_tools}/steam-runtime-launcher-service"
  chmod +x -- "${runtime_tools}/steam-runtime-launcher-service"
  ln -s -- /x86/32 "${guest_home}/.steam/bin32"
  ln -s -- /x86/64 "${guest_home}/.steam/bin64"
  printf '#!%s\n' "${TEST_BASH}" >"${guest_root}/restart-command"
  cat >>"${guest_root}/restart-command" <<'EOF'
set -o errexit
set -o nounset

attempt=0
if [[ -f ${TEST_STATUS_FILE} ]]; then
  attempt=$(<"${TEST_STATUS_FILE}")
fi
((attempt += 1))
printf '%s\n' "${attempt}" >"${TEST_STATUS_FILE}"
printf '%s\n' "${PATH}" >"${TEST_OUTPUT}/path"
printf '%s\n' "${LD_LIBRARY_PATH}" >"${TEST_OUTPUT}/library-path"
printf '%s\n' "${GIO_EXTRA_MODULES-unset}" >"${TEST_OUTPUT}/gio-extra-modules"
printf '%s\n' "${XDG_DATA_DIRS}" >"${TEST_OUTPUT}/data-dirs"
printf '%s\n' "${VK_DRIVER_FILES}" >"${TEST_OUTPUT}/vulkan-drivers"
printf '%s\n' "$@" >"${TEST_OUTPUT}/arguments"
((attempt == 1)) && exit "${TEST_STEAM_RESTART_EXIT_STATUS}"
exit "${TEST_GUEST_COMMAND_EXIT_STATUS}"
EOF
  chmod +x -- "${guest_root}/restart-command"

  run_expect_status "${TEST_GUEST_COMMAND_EXIT_STATUS}" \
    env -u LD_LIBRARY_PATH \
    NATIVE_LIBRARY_PATH=/declared/native \
    GIO_EXTRA_MODULES=/host/gio \
    HOME="${guest_home}" \
    XDG_DATA_DIRS=/host/share \
    VK_DRIVER_FILES=/custom/vulkan.json \
    XDG_DATA_HOME="${guest_root}/data home" \
    TEST_OUTPUT="${output}" \
    TEST_STATUS_FILE="${status_file}" \
    bash "${PACKAGE_ROOT}/scripts/guest.sh" \
    --steam "${guest_root}/restart-command" 'argument with spaces' '*'

  assert_equal 2 "$(<"${status_file}")" 'guest restart count'
  [[ ! -L ${guest_home}/.steam/bin32 ]] \
    || fail 'guest did not remove the x86 32-bit overlay link'
  [[ ! -L ${guest_home}/.steam/bin64 ]] \
    || fail 'guest did not remove the x86 64-bit overlay link'
  expected_library_path="${guest_root}/data home/Steam/steamrtarm64:\
${guest_root}/data home/Steam/steamrtarm64/libs:\
/run/opengl-driver/lib:/declared/native"
  assert_equal \
    "${expected_library_path}" \
    "$(<"${output}/library-path")" \
    'guest library path'
  [[ $(<"${output}/path") != *: ]] \
    || fail 'guest PATH has an empty final entry'
  [[ $(<"${output}/path") == \
    "/usr/local/bin:/usr/bin:/bin:${runtime_tools}:"* ]] \
    || fail 'guest PATH does not include ARM64 Steam Runtime tools'
  assert_equal unset "$(<"${output}/gio-extra-modules")" \
    'guest GIO_EXTRA_MODULES isolation'
  expected_data_directories="/run/opengl-driver/share:\
/run/current-system/sw/share:/usr/local/share:/usr/share:/host/share"
  assert_equal \
    "${expected_data_directories}" \
    "$(<"${output}/data-dirs")" \
    'guest XDG data directories'
  assert_equal /custom/vulkan.json "$(<"${output}/vulkan-drivers")" \
    'guest Vulkan override preservation'
  assert_file_lines \
    "${output}/arguments" \
    'guest argument' \
    'argument with spaces' \
    '*'

  run_expect_status 1 \
    env NATIVE_LIBRARY_PATH=/native \
    bash "${PACKAGE_ROOT}/scripts/guest.sh"
  run_expect_status 1 \
    env NATIVE_LIBRARY_PATH=/native \
    bash "${PACKAGE_ROOT}/scripts/guest.sh" --steam
}

test_proton_runner() {
  local expected_library_path
  local fake_bin="${TEST_ROOT}/proton-runner/fake-bin"
  local output="${TEST_ROOT}/proton-runner/output"
  local tool="${TEST_ROOT}/proton-runner/tool with spaces"

  mkdir -p -- "${fake_bin}" "${output}" "${tool}/proton"
  cp -- "${PACKAGE_ROOT}/proton/run-proton" "${tool}/run-proton"
  chmod +x -- "${tool}/run-proton"
  printf '#!%s\n' "${TEST_SH}" >"${fake_bin}/python3"
  cat >>"${fake_bin}/python3" <<'EOF'
printf '%s\n' "${LD_LIBRARY_PATH}" >"${TEST_OUTPUT}/library-path"
printf '%s\n' "$@" >"${TEST_OUTPUT}/arguments"
exit "${TEST_PROTON_RUNNER_EXIT_STATUS}"
EOF
  chmod +x -- "${fake_bin}/python3"

  run_expect_status "${TEST_PROTON_RUNNER_EXIT_STATUS}" \
    env -u LD_LIBRARY_PATH \
    PATH="${fake_bin}:${PATH}" \
    TEST_OUTPUT="${output}" \
    "${tool}/run-proton" waitforexitandrun 'game with spaces.exe'

  expected_library_path="${tool}/host-libs:\
/usr/lib/pressure-vessel/overrides/lib/aarch64-linux-gnu:\
/usr/lib/pressure-vessel/overrides/lib"
  assert_equal \
    "${expected_library_path}" \
    "$(<"${output}/library-path")" \
    'Proton runner library path'
  assert_file_lines \
    "${output}/arguments" \
    'Proton runner argument' \
    "${tool}/proton/proton" \
    waitforexitandrun \
    'game with spaces.exe'
}

test_proton_wrapper() {
  local output="${TEST_ROOT}/proton-wrapper/output"
  local standard_error="${TEST_ROOT}/proton-wrapper/stderr"
  local tool="${TEST_ROOT}/proton-wrapper/tool with spaces"

  mkdir -p -- "${output}" "${tool}/runtime"
  cp -- "${PACKAGE_ROOT}/proton/steam-asahi-proton" \
    "${tool}/steam-asahi-proton"
  chmod +x -- "${tool}/steam-asahi-proton"
  touch "${tool}/run-proton"
  printf '#!%s\n' "${TEST_SH}" >"${tool}/runtime/_v2-entry-point"
  cat >>"${tool}/runtime/_v2-entry-point" <<'EOF'
printf '%s\n' "${STEAM_COMPAT_APP_ID:-}" >"${TEST_OUTPUT}/app-id"
printf '%s\n' "${STEAM_COMPAT_DATA_PATH:-}" >"${TEST_OUTPUT}/compat-data"
printf '%s\n' "$@" >"${TEST_OUTPUT}/arguments"
printf 'runtime output for app %s\n' "${STEAM_COMPAT_APP_ID:-unset}"
exit "${TEST_PROTON_RUNTIME_EXIT_STATUS}"
EOF
  chmod +x -- "${tool}/runtime/_v2-entry-point"

  run_expect_status "${TEST_PROTON_RUNTIME_EXIT_STATUS}" \
    env SteamAppId="${TEST_APP_ID}" \
    STEAM_COMPAT_DATA_PATH="${TEST_ROOT}/compatdata/0/" \
    TEST_OUTPUT="${output}" \
    "${tool}/steam-asahi-proton" run 'argument with spaces' \
    2>"${standard_error}"

  assert_equal \
    "${TEST_APP_ID}" "$(<"${output}/app-id")" 'recovered Steam app ID'
  assert_equal \
    "${TEST_ROOT}/compatdata/${TEST_APP_ID}" \
    "$(<"${output}/compat-data")" \
    'repaired Steam compatdata path'
  [[ -d ${TEST_ROOT}/compatdata/${TEST_APP_ID} ]] \
    || fail 'compatdata was not created'
  assert_file_lines \
    "${output}/arguments" \
    'runtime argument' \
    '--verb=run' \
    -- \
    "${tool}/run-proton" \
    run \
    'argument with spaces'
  assert_file_contains_line \
    "${tool}/steam-asahi-proton.log" \
    'command: <argument with spaces>'
  assert_file_contains_line \
    "${standard_error}" \
    "ERROR: Proton compatibility command exited with status \
${TEST_PROTON_RUNTIME_EXIT_STATUS}."
  grep -F -- "runtime output for app ${TEST_APP_ID}" \
    "${standard_error}" >/dev/null \
    || fail 'Proton failure output was not replayed to standard error'

  run_expect_status "${TEST_PROTON_RUNTIME_EXIT_STATUS}" \
    env SteamAppId=0 \
    STEAM_COMPAT_DATA_PATH="${TEST_ROOT}/probe/0" \
    TEST_OUTPUT="${output}" \
    "${tool}/steam-asahi-proton" run
  assert_equal \
    "${TEST_ROOT}/probe/steam-asahi-tool" \
    "$(<"${output}/compat-data")" \
    'tool probe compatdata path'
  assert_file_contains_line "${tool}/steam-asahi-proton.log" 'command:'

  run_expect_status 2 "${tool}/steam-asahi-proton"
}

test_launcher() {
  local configurator_output="${TEST_ROOT}/launcher/configurator-arguments"
  local launcher_root="${TEST_ROOT}/launcher"
  local home="${launcher_root}/home with spaces"
  local output="${launcher_root}/muvm-arguments"
  local steam_home="${home}/data/steam-asahi-arm64-home"
  local steam_directory="${steam_home}/.local/share/Steam"
  local compatibility_directory=\
"${steam_directory}/compatibilitytools.d/test-proton"
  local -ar executable_files=(
    "${launcher_root}/bootstrap/steam"
    "${launcher_root}/proton-runner"
    "${launcher_root}/proton-wrapper"
    "${steam_directory}/steamapps/common/Test Proton/proton"
    "${steam_directory}/steamapps/common/Test Runtime/_v2-entry-point"
  )
  local -ar metadata_files=(
    "${launcher_root}/compatibilitytool.vdf"
    "${launcher_root}/toolmanifest.vdf"
  )

  if ((EUID == 0)); then
    printf '%s\n' 'SKIP: launcher behavioral test refuses to run as root'
    return
  fi

  mkdir -p -- \
    "${launcher_root}/bootstrap" \
    "${launcher_root}/host-libs" \
    "${steam_directory}/steamapps/common/Test Proton" \
    "${steam_directory}/steamapps/common/Test Runtime"
  touch -- "${executable_files[@]}" "${metadata_files[@]}"
  chmod +x -- "${executable_files[@]}"
  printf '#!%s\n' "${TEST_SH}" >"${launcher_root}/configurator"
  cat >>"${launcher_root}/configurator" <<'EOF'
printf '%s\n' "$@" >"${TEST_CONFIGURATOR_OUTPUT}"
EOF
  chmod +x -- "${launcher_root}/configurator"
  printf '#!%s\n' "${TEST_SH}" >"${launcher_root}/muvm"
  cat >>"${launcher_root}/muvm" <<'EOF'
printf '%s\n' "$@" >"${TEST_MUVM_OUTPUT}"
if [[ -n "${TEST_MUVM_HOLD_FILE:-}" ]]; then
  touch -- "${TEST_MUVM_HOLD_FILE}.ready"
  while [[ -e "${TEST_MUVM_HOLD_FILE}" ]]; do
    sleep 0.05
  done
fi
EOF
  chmod +x -- "${launcher_root}/muvm"

  run_test_launcher() {
    env \
      CLIENT_BOOTSTRAP="${launcher_root}/bootstrap" \
      CLIENT_UPDATE_CHANNEL=publicbeta \
      COMPATIBILITY_TOOL_DIRECTORY=test-proton \
      COMPATIBILITY_TOOL_VDF="${launcher_root}/compatibilitytool.vdf" \
      CUSTOM_STEAM_HOME_DIR= \
      DEFAULT_STEAM_HOME_DIR=steam-asahi-arm64-home \
      DISPLAY_NAME='Test Proton' \
      ENV_BIN="$(command -v env)" \
      FLOCK="$(command -v flock)" \
      GUEST_LAUNCHER=/guest-launcher \
      HOME="${home}" \
      HOST_LIBRARIES="${launcher_root}/host-libs" \
      INIT_SCRIPT=/init-script \
      MUVM="${launcher_root}/muvm" \
      PROTON_DIRECTORY='Test Proton' \
      PROTON_CONFIGURATOR="${launcher_root}/configurator" \
      PROTON_RUNNER="${launcher_root}/proton-runner" \
      PROTON_TOOL_NAME=proton_test \
      PROTON_WRAPPER="${launcher_root}/proton-wrapper" \
      RUNTIME_APP_ID=123 \
      RUNTIME_DIRECTORY='Test Runtime' \
      STEAM_ASAHI_NO_SPLASH=1 \
      TEST_CONFIGURATOR_OUTPUT="${configurator_output}" \
      TEST_MUVM_HOLD_FILE="${TEST_MUVM_HOLD_FILE:-}" \
      TEST_MUVM_OUTPUT="${output}" \
      TOOL_MANIFEST="${launcher_root}/toolmanifest.vdf" \
      XDG_DATA_HOME="${home}/data" \
      YAD=/bin/false \
      bash "${PACKAGE_ROOT}/scripts/launcher.sh" "$@"
  }

  run_test_launcher --force-proton "${FORCE_PROTON_APP_ID}"

  [[ -x ${steam_directory}/steamrtarm64/steam ]] ||
    fail 'Steam bootstrap was not installed'
  assert_equal publicbeta "$(<"${steam_directory}/package/beta")" \
    'Steam update channel'
  assert_equal \
    "${steam_directory}" "$(readlink -- "${steam_home}/.steam/steam")" \
    'Steam compatibility symlink'
  [[ -x ${compatibility_directory}/run-proton ]] ||
    fail 'managed Proton runner was not installed'
  [[ -L ${compatibility_directory}/host-libs ]] ||
    fail 'managed host-library link was not installed'
  assert_file_contains_line "${output}" '--gpu-mode=drm'
  assert_file_contains_line "${output}" '--steam'
  assert_file_contains_line \
    "${output}" "steam://run/${FORCE_PROTON_APP_ID}"
  assert_file_contains_line \
    "${configurator_output}" \
    "${steam_directory}/config/config.vdf"
  assert_file_contains_line \
    "${configurator_output}" "${FORCE_PROTON_APP_ID}"
  assert_file_contains_line "${configurator_output}" proton_test

  local hold_file="${launcher_root}/hold-muvm"
  local running_pid
  touch -- "${hold_file}"
  TEST_MUVM_HOLD_FILE="${hold_file}" \
    run_test_launcher steam://open/games \
    >"${launcher_root}/running-output" \
    2>&1 &
  running_pid=$!
  while [[ ! -e "${hold_file}.ready" ]]; do
    kill -0 "${running_pid}" 2>/dev/null \
      || fail 'background launcher exited before acquiring its lock'
    sleep 0.05
  done
  if run_test_launcher --force-proton "${FORCE_PROTON_APP_ID}" \
    2>"${launcher_root}/lock-error"; then
    fail 'a second launcher bypassed the host-side Steam lock'
  fi
  grep -F \
    'ERROR: Close Steam before changing a compatibility-tool mapping' \
    "${launcher_root}/lock-error" >/dev/null \
    || fail 'the lock conflict did not explain how to proceed'
  rm -f -- "${hold_file}"
  wait "${running_pid}"

  if find "${steam_directory}" -name '.*.??????' -print -quit | grep -q .; then
    fail 'launcher left a managed-file temporary path behind'
  fi
}

main() {
  test_sourceability
  test_guest_launcher
  test_proton_runner
  test_proton_wrapper
  test_launcher
  printf '%s\n' 'All steam-asahi ARM64 shell tests passed.'
}

main "$@"
