#!/usr/bin/env python3

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import pexpect


VARIABLE_NAME = "APPLE_2FA_CODE"
WAITING_VALUE = "WAITING_FOR_2FA"
API_VERSION = "2022-11-28"


def api_request(method: str, path: str, body: dict | None = None):
    token = os.environ["OTP_GITHUB_TOKEN"]
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": API_VERSION,
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = response.read()
        return json.loads(payload) if payload else None


def variable_path() -> str:
    owner, repository = os.environ["GITHUB_REPOSITORY"].split("/", 1)
    return f"/repos/{owner}/{repository}/actions/variables/{VARIABLE_NAME}"


def set_waiting_variable():
    path = variable_path()
    try:
        api_request("PATCH", path, {"name": VARIABLE_NAME, "value": WAITING_VALUE})
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        owner, repository = os.environ["GITHUB_REPOSITORY"].split("/", 1)
        api_request(
            "POST",
            f"/repos/{owner}/{repository}/actions/variables",
            {"name": VARIABLE_NAME, "value": WAITING_VALUE},
        )


def delete_variable():
    try:
        api_request("DELETE", variable_path())
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise


def read_variable() -> str | None:
    try:
        result = api_request("GET", variable_path())
        return result.get("value") if result else None
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def append_summary(message: str):
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write(f"\n{message}\n")


def wait_for_code(timeout_seconds: int = 600) -> str:
    set_waiting_variable()
    print("::notice title=Apple 2FA::WAITING_FOR_2FA — send the current six-digit code now.", flush=True)
    append_summary("🟡 **WAITING_FOR_2FA** — send the current six-digit Apple code now.")
    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline:
        value = read_variable()
        if value and re.fullmatch(r"\d{6}", value):
            print(f"::add-mask::{value}", flush=True)
            delete_variable()
            print("A six-digit code was received, masked, and removed from the repository variable.", flush=True)
            return value
        if value not in (None, WAITING_VALUE):
            set_waiting_variable()
        time.sleep(2)

    delete_variable()
    raise TimeoutError("No six-digit code was received within 10 minutes.")


class Tee:
    def __init__(self, path: str):
        self.file = open(path, "w", encoding="utf-8")
        self.last_write = time.monotonic()

    def write(self, data: str):
        if data:
            self.last_write = time.monotonic()
        sys.stdout.write(data)
        sys.stdout.flush()
        self.file.write(data)
        self.file.flush()

    def flush(self):
        sys.stdout.flush()
        self.file.flush()

    def close(self):
        self.file.close()


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: install-with-2fa.py LOG_PATH COMMAND [ARGS...]", file=sys.stderr)
        return 64

    log = Tee(sys.argv[1])
    child = pexpect.spawn(
        sys.argv[2],
        sys.argv[3:],
        env=os.environ.copy(),
        encoding="utf-8",
        echo=False,
        timeout=None,
    )
    child.logfile_read = log

    try:
        while True:
            match = child.expect(
                [r"Enter (?:the )?6 digit code[^:]*:", pexpect.EOF, pexpect.TIMEOUT],
                timeout=60,
            )
            if match == 1:
                break
            if match == 2:
                if time.monotonic() - log.last_write >= 180:
                    raise TimeoutError("xcodes produced no output for three minutes.")
                continue
            code = wait_for_code()
            child.sendline(code)
    except Exception as error:
        print(f"2FA mailbox failed: {type(error).__name__}: {error}", file=sys.stderr)
        child.terminate(force=True)
        return 90
    finally:
        try:
            delete_variable()
        except Exception as error:
            print(f"Warning: could not delete {VARIABLE_NAME}: {error}", file=sys.stderr)
        child.close()
        log.close()

    if child.exitstatus is not None:
        return child.exitstatus
    if child.signalstatus is not None:
        return 128 + child.signalstatus
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
