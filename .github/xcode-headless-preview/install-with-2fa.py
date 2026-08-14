#!/usr/bin/env python3

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

import pexpect


API_VERSION = "2022-11-28"
issue_number = None
private_key_path = None


def api_request(method: str, path: str, body: dict | None = None):
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {os.environ['OTP_GITHUB_TOKEN']}",
            "X-GitHub-Api-Version": API_VERSION,
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = response.read()
        return json.loads(payload) if payload else None


def repository_path() -> str:
    owner, repository = os.environ["GITHUB_REPOSITORY"].split("/", 1)
    return f"/repos/{owner}/{repository}"


def create_mailbox() -> str:
    global issue_number, private_key_path
    key_dir = tempfile.mkdtemp(prefix="apple-2fa-")
    private_key_path = os.path.join(key_dir, "private.pem")
    public_key_path = os.path.join(key_dir, "public.pem")
    subprocess.run(
        ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", private_key_path],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["openssl", "pkey", "-in", private_key_path, "-pubout", "-out", public_key_path],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    with open(public_key_path, "r", encoding="utf-8") as key_file:
        public_key = key_file.read()
    run_id = os.environ.get("GITHUB_RUN_ID", "unknown")
    issue = api_request(
        "POST",
        f"{repository_path()}/issues",
        {
            "title": f"[Swift Lab] Waiting for encrypted Apple 2FA — run {run_id}",
            "body": (
                "This temporary mailbox contains no password or verification code. "
                "The six-digit code must be RSA-OAEP encrypted with this one-time public key.\n\n"
                f"```pem\n{public_key}```\n"
            ),
        },
    )
    issue_number = issue["number"]
    return issue["html_url"]


def read_code() -> str | None:
    if issue_number is None or private_key_path is None:
        return None
    comments = api_request("GET", f"{repository_path()}/issues/{issue_number}/comments?per_page=100")
    prefix = "APPLE_2FA_CIPHERTEXT:"
    for comment in reversed(comments or []):
        body = (comment.get("body") or "").strip()
        if not body.startswith(prefix):
            continue
        try:
            ciphertext = base64.b64decode(body[len(prefix):].strip(), validate=True)
            result = subprocess.run(
                ["openssl", "pkeyutl", "-decrypt", "-inkey", private_key_path, "-pkeyopt", "rsa_padding_mode:oaep"],
                input=ciphertext,
                check=True,
                capture_output=True,
            )
            code = result.stdout.decode("utf-8").strip()
            if re.fullmatch(r"\d{6}", code):
                return code
        except (ValueError, subprocess.CalledProcessError, UnicodeDecodeError):
            continue
    return None


def close_mailbox():
    if issue_number is None:
        return
    api_request(
        "PATCH",
        f"{repository_path()}/issues/{issue_number}",
        {
            "state": "closed",
            "title": f"[Swift Lab] Encrypted Apple 2FA mailbox closed — run {os.environ.get('GITHUB_RUN_ID', 'unknown')}",
        },
    )


def append_summary(message: str):
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write(f"\n{message}\n")


def wait_for_code(timeout_seconds: int = 600) -> str:
    mailbox_url = create_mailbox()
    print(f"::notice title=Apple 2FA::WAITING_FOR_2FA — encrypted mailbox: {mailbox_url}", flush=True)
    append_summary(f"**WAITING_FOR_2FA** — encrypted mailbox: {mailbox_url}")
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        code = read_code()
        if code:
            print(f"::add-mask::{code}", flush=True)
            close_mailbox()
            print("The encrypted six-digit code was received and masked.", flush=True)
            return code
        time.sleep(2)
    close_mailbox()
    raise TimeoutError("No encrypted six-digit code was received within 10 minutes.")


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
    child = pexpect.spawn(sys.argv[2], sys.argv[3:], env=os.environ.copy(), encoding="utf-8", echo=False, timeout=None)
    child.logfile_read = log
    try:
        while True:
            match = child.expect([r"Enter (?:the )?6 digit code[^:]*:", pexpect.EOF, pexpect.TIMEOUT], timeout=60)
            if match == 1:
                break
            if match == 2:
                if time.monotonic() - log.last_write >= 180:
                    raise TimeoutError("xcodes produced no output for three minutes.")
                continue
            child.sendline(wait_for_code())
    except Exception as error:
        print(f"2FA mailbox failed: {type(error).__name__}: {error}", file=sys.stderr)
        child.terminate(force=True)
        return 90
    finally:
        try:
            close_mailbox()
        except Exception as error:
            print(f"Warning: could not close the encrypted mailbox: {error}", file=sys.stderr)
        child.close()
        log.close()
    if child.exitstatus is not None:
        return child.exitstatus
    if child.signalstatus is not None:
        return 128 + child.signalstatus
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
