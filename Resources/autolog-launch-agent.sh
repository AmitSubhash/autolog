#!/usr/bin/env bash

set -euo pipefail

APP_BUNDLE="${1:-/Applications/AutoLog.app}"
APP_BIN="${APP_BUNDLE}/Contents/MacOS/ContextD"
APP_NAME="AutoLog"
STATE_DIR="${HOME}/Library/Application Support/ContextD/launch-agent"
QUIT_SENTINEL="${STATE_DIR}/user-quit"
STDOUT_LOG="${HOME}/Library/Logs/autolog-app.log"
STDERR_LOG="${HOME}/Library/Logs/autolog-app.err"

mkdir -p "${STATE_DIR}" "$(dirname "${STDOUT_LOG}")"
touch "${STDOUT_LOG}" "${STDERR_LOG}"

timestamp() {
    /bin/date "+%Y-%m-%d %H:%M:%S"
}

log_info() {
    printf '[%s] [INFO] [LaunchAgent] %s\n' "$(timestamp)" "$1" >> "${STDOUT_LOG}"
}

log_error() {
    printf '[%s] [ERROR] [LaunchAgent] %s\n' "$(timestamp)" "$1" >> "${STDERR_LOG}"
}

find_pid() {
    /usr/bin/pgrep -fx "${APP_BIN}" | /usr/bin/head -n 1 || true
}

wait_for_pid() {
    local pid=""
    for _ in $(seq 1 50); do
        pid="$(find_pid)"
        if [ -n "${pid}" ]; then
            printf '%s\n' "${pid}"
            return 0
        fi
        /bin/sleep 0.2
    done
    return 1
}

/bin/rm -f "${QUIT_SENTINEL}"

while true; do
    /bin/rm -f "${QUIT_SENTINEL}"

    if ! /usr/bin/open "${APP_BUNDLE}" >> "${STDOUT_LOG}" 2>> "${STDERR_LOG}"; then
        log_error "Failed to launch ${APP_NAME}; retrying in 5s"
        /bin/sleep 5
        continue
    fi

    pid="$(wait_for_pid || true)"
    if [ -z "${pid}" ]; then
        log_error "${APP_NAME} did not produce a pid after launch; retrying in 5s"
        /bin/sleep 5
        continue
    fi

    log_info "${APP_NAME} started with pid ${pid}"

    while /bin/kill -0 "${pid}" 2>/dev/null; do
        /bin/sleep 1
    done

    if [ -f "${QUIT_SENTINEL}" ]; then
        /bin/rm -f "${QUIT_SENTINEL}"
        log_info "${APP_NAME} exited gracefully; wrapper stopping"
        exit 0
    fi

    log_error "${APP_NAME} exited unexpectedly; relaunching in 2s"
    /bin/sleep 2
done
