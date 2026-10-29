import base64
import ctypes
from ctypes import wintypes
import hashlib
import hmac
import http.server
import json
import os
import re
import secrets
import shutil
import socketserver
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import Request, urlopen

from playwright.sync_api import sync_playwright


OAUTH_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
OAUTH_ISSUER = "https://auth.openai.com"


class OAuthCallbackServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, state):
        self.state = state
        self.callback_event = threading.Event()
        self.code = None
        self.error = None
        self._handler = self._make_handler()
        last_error = None
        for port in (1455, 1457):
            try:
                super().__init__(("127.0.0.1", port), self._handler, bind_and_activate=True)
                return
            except OSError as error:
                last_error = error
        raise RuntimeError("Deck could not bind the Codex OAuth callback ports.") from last_error

    def _make_handler(self):
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urlparse(self.path)
                query = parse_qs(parsed.query)
                if parsed.path != "/auth/callback":
                    self.send_error(404)
                    return
                if query.get("state", [""])[0] != owner.state:
                    owner.error = "OAuth callback state did not match."
                elif query.get("error"):
                    owner.error = "OpenAI sign-in returned an OAuth error."
                else:
                    owner.code = query.get("code", [None])[0]
                    if not owner.code:
                        owner.error = "OpenAI sign-in returned no authorization code."
                body = b"Sign-in received. You can close this tab and return to Codex Deck."
                self.send_response(200 if owner.code else 400)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                owner.callback_event.set()

            def log_message(self, *_args):
                return

        return Handler


def oauth_authorization_url(callback_server, verifier, state):
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).decode("ascii").rstrip("=")
    redirect_uri = f"http://127.0.0.1:{callback_server.server_port}/auth/callback"
    parameters = {
        "response_type": "code",
        "client_id": OAUTH_CLIENT_ID,
        "redirect_uri": redirect_uri,
        "scope": "openid profile email offline_access api.connectors.read api.connectors.invoke",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
        "id_token_add_organizations": "true",
        "codex_cli_simplified_flow": "true",
        "originator": "codex_cli_rs",
    }
    return f"{OAUTH_ISSUER}/oauth/authorize?{urlencode(parameters)}", redirect_uri


def _jwt_claims(token):
    parts = token.split(".")
    if len(parts) != 3:
        raise RuntimeError("OpenAI returned an invalid ID token.")
    payload = parts[1] + "=" * ((4 - len(parts[1]) % 4) % 4)
    return json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))


def exchange_oauth_code(code, redirect_uri, verifier):
    body = urlencode({
        "grant_type": "authorization_code",
        "client_id": OAUTH_CLIENT_ID,
        "code": code,
        "redirect_uri": redirect_uri,
        "code_verifier": verifier,
    }).encode("ascii")
    request = Request(
        f"{OAUTH_ISSUER}/oauth/token",
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=30) as response:
            result = json.loads(response.read())
    except Exception as error:
        raise RuntimeError("Deck could not exchange the OAuth authorization code.") from error
    if not all(result.get(key) for key in ("id_token", "access_token", "refresh_token")):
        raise RuntimeError("OpenAI returned incomplete OAuth credentials.")
    return result


def save_codex_auth(codex_home, token_result, expected_email):
    claims = _jwt_claims(token_result["id_token"])
    auth_claims = claims.get("https://api.openai.com/auth") or {}
    email = claims.get("email") or (claims.get("https://api.openai.com/profile") or {}).get("email")
    if not email or email.casefold() != expected_email.casefold():
        raise RuntimeError("Signed-in account email did not match the Deck helper entry.")
    account_id = auth_claims.get("chatgpt_account_id")
    if not account_id:
        raise RuntimeError("OpenAI ID token did not include a ChatGPT account ID.")
    auth = {
        "auth_mode": "chatgpt",
        "OPENAI_API_KEY": None,
        "tokens": {
            "id_token": token_result["id_token"],
            "access_token": token_result["access_token"],
            "refresh_token": token_result["refresh_token"],
            "account_id": account_id,
        },
        "last_refresh": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    }
    os.makedirs(codex_home, exist_ok=True)
    auth_path = os.path.join(codex_home, "auth.json")
    temp_path = auth_path + ".deck-login-" + secrets.token_hex(6) + ".tmp"
    try:
        with open(temp_path, "x", encoding="utf-8") as output:
            json.dump(auth, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp_path, auth_path)
    finally:
        try:
            os.remove(temp_path)
        except OSError:
            pass


def _descendant_process_ids(root_pid):
    if os.name != "nt":
        return set()
    class ProcessEntry32(ctypes.Structure):
        _fields_ = [
            ("dwSize", ctypes.c_ulong), ("cntUsage", ctypes.c_ulong),
            ("th32ProcessID", ctypes.c_ulong), ("th32DefaultHeapID", ctypes.c_size_t),
            ("th32ModuleID", ctypes.c_ulong), ("cntThreads", ctypes.c_ulong),
            ("th32ParentProcessID", ctypes.c_ulong), ("pcPriClassBase", ctypes.c_long),
            ("dwFlags", ctypes.c_ulong), ("szExeFile", ctypes.c_wchar * 260),
        ]
    kernel = ctypes.windll.kernel32
    kernel.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    kernel.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry32)]
    kernel.Process32FirstW.restype = wintypes.BOOL
    kernel.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(ProcessEntry32)]
    kernel.Process32NextW.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    snapshot = kernel.CreateToolhelp32Snapshot(0x00000002, 0)
    if snapshot == wintypes.HANDLE(-1).value:
        return set()
    children = {}
    try:
        entry = ProcessEntry32()
        entry.dwSize = ctypes.sizeof(entry)
        if kernel.Process32FirstW(snapshot, ctypes.byref(entry)):
            while True:
                children.setdefault(entry.th32ParentProcessID, set()).add(entry.th32ProcessID)
                if not kernel.Process32NextW(snapshot, ctypes.byref(entry)):
                    break
    finally:
        kernel.CloseHandle(snapshot)
    descendants = set()
    pending = [root_pid]
    while pending:
        parent = pending.pop()
        for child in children.get(parent, ()):
            if child not in descendants:
                descendants.add(child)
                pending.append(child)
    return descendants


def _hide_browser_windows(stop_event, root_pid):
    if os.name != "nt":
        return
    user32 = ctypes.windll.user32
    enum_callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = [enum_callback_type, wintypes.LPARAM]
    user32.EnumWindows.restype = wintypes.BOOL
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.IsWindowVisible.restype = wintypes.BOOL
    user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.ShowWindow.restype = wintypes.BOOL
    while not stop_event.is_set():
        process_ids = _descendant_process_ids(root_pid)
        if process_ids:
            @enum_callback_type
            def hide(hwnd, _lparam):
                pid = ctypes.c_ulong()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                if pid.value in process_ids and user32.IsWindowVisible(hwnd):
                    user32.ShowWindow(hwnd, 0)
                return True
            user32.EnumWindows(hide, 0)
        stop_event.wait(0.05)


def totp(secret: str) -> str:
    value = re.sub(r"\s+", "", secret or "").replace("-", "").rstrip("=")
    padding = "=" * ((8 - len(value) % 8) % 8)
    key = base64.b32decode((value + padding).upper(), casefold=True)
    counter = int(time.time() // 30).to_bytes(8, "big")
    digest = hmac.new(key, counter, hashlib.sha1).digest()
    offset = digest[-1] & 15
    number = int.from_bytes(digest[offset : offset + 4], "big") & 0x7FFFFFFF
    return f"{number % 1000000:06d}"


def first_visible(page, selectors):
    for selector in selectors:
        locator = page.locator(selector).first
        try:
            if locator.is_visible():
                return locator
        except Exception:
            pass
    return None


def fill_first(page, selectors, value):
    field = first_visible(page, selectors)
    if field is None:
        return False
    field.fill(value)
    return True


def click_continue(page):
    for selector in (
        "button[type=submit]",
        "button:has-text('Continue')",
        "button:has-text('Next')",
        "input[type=submit]",
    ):
        button = first_visible(page, [selector])
        if button is not None:
            button.click()
            return True
    return False


def fill_otp(field, page, code):
    if field.get_attribute("maxlength") == "1":
        digits = page.locator("input[maxlength='1']")
        if digits.count() >= len(code):
            for index, digit in enumerate(code):
                digits.nth(index).fill(digit)
            return
    field.fill(code)


def body_text(page):
    try:
        return page.locator("body").inner_text(timeout=500)
    except Exception:
        return ""


def safe_page_diagnostics(page, expected_email):
    try:
        details = page.evaluate("""() => {
            const visible = element => {
                const style = getComputedStyle(element);
                const rect = element.getBoundingClientRect();
                return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
            };
            const inputs = [...document.querySelectorAll('input, button, [role=button]')]
                .filter(visible).slice(0, 16).map(element => ({
                    tag: element.tagName.toLowerCase(),
                    type: element.getAttribute('type') || '',
                    name: element.getAttribute('name') || '',
                    autocomplete: element.getAttribute('autocomplete') || '',
                    label: (element.innerText || element.getAttribute('aria-label') || '').trim().slice(0, 48)
                }));
            const text = (document.body?.innerText || '').toLowerCase();
            return {
                title: document.title || '',
                ready: document.readyState,
                inputs,
                forms: document.forms.length,
                frames: [...document.querySelectorAll('iframe')].map(frame => {
                    try { return new URL(frame.src).host; } catch { return 'unknown'; }
                }).slice(0, 8),
                body: (document.body?.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 240),
                signals: Object.fromEntries(['email', 'password', 'continue', 'captcha', 'verify', 'browser', 'javascript', 'cookie'].map(word => [word, text.includes(word)]))
            };
        }""")
        title = str(details.get("title", ""))
        body = str(details.get("body", ""))
        if expected_email:
            title = re.sub(re.escape(expected_email), "<email>", title, flags=re.IGNORECASE)
            body = re.sub(re.escape(expected_email), "<email>", body, flags=re.IGNORECASE)
        title = re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "<email>", title)
        body = re.sub(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "<email>", body)
        body = re.sub(r"\b\d{6,}\b", "<number>", body)
        body = re.sub(r"\b[A-Za-z0-9_-]{32,}\b", "<code>", body)
        details["title"] = title[:100]
        safe_url = urlparse(page.url)
        return json.dumps({
            "title": details.get("title", ""),
            "body": body[:240],
            "ready": details.get("ready", ""),
            "inputs": details.get("inputs", []),
            "forms": details.get("forms", 0),
            "frames": details.get("frames", []),
            "signals": details.get("signals", {}),
            "url": (safe_url.hostname or "OpenAI") + safe_url.path,
        }, separators=(",", ":"))
    except Exception:
        parsed = urlparse(page.url)
        return json.dumps({"url": (parsed.hostname or "OpenAI") + parsed.path, "diagnostics": "unavailable"})


def complete_login(payload):
    verification_url = payload["verification_url"]
    email = payload["email"]
    password = payload["password"]
    otp_secret = payload.get("otp", "")
    browser_path = payload.get("browser_path")
    show_browser = bool(payload.get("show_browser"))
    temp_profile = tempfile.mkdtemp(prefix="codex-deck-auth-")
    context = None
    hide_stop = threading.Event()
    hide_thread = None
    if not show_browser:
        hide_thread = threading.Thread(
            target=_hide_browser_windows,
            args=(hide_stop, os.getpid()),
            name="codex-deck-hide-oauth-window",
            daemon=True,
        )
        hide_thread.start()
    try:
        with sync_playwright() as playwright:
            # Hidden refreshes never expose a browser window. The one-time
            # visible path lets the account owner complete provider verification.
            launch = {
                "headless": False,
                "args": (
                    ["--window-position=80,80", "--window-size=1100,850"]
                    if show_browser else
                    ["--start-minimized", "--window-position=-32000,-32000", "--window-size=900,700"]
                ),
            }
            if browser_path:
                launch["executable_path"] = browser_path
            context = playwright.chromium.launch_persistent_context(temp_profile, **launch)
            page = context.pages[0] if context.pages else context.new_page()
            page.goto(verification_url, wait_until="domcontentloaded", timeout=30000)
            page.wait_for_timeout(1000)

            password_submitted = False
            email_submitted = False
            consent_clicked = False
            otp_submitted_at = 0.0
            error_retries = 0
            security_challenge_started = None
            started_at = time.time()
            deadline = started_at + (240 if show_browser else 45)
            while time.time() < deadline:
                try:
                    page_title = page.title().lower()
                except Exception:
                    page_title = ""
                if "oops, an error occurred" in page_title:
                    retry_button = first_visible(page, ["button:has-text('Try again')"])
                    if retry_button is not None and error_retries < 2:
                        error_retries += 1
                        retry_button.click()
                        page.wait_for_timeout(1500)
                        continue
                    diagnostic = safe_page_diagnostics(page, email)
                    raise RuntimeError(f"OpenAI sign-in page returned an error after retry; page state: {diagnostic}")
                email_field = first_visible(page, [
                    "input[type='email']",
                    "input[name='email']",
                    "input[autocomplete='username']",
                    "input[placeholder*='email' i]",
                ])
                if email_field is not None and not email_submitted:
                    email_field.fill(email)
                    if not click_continue(page):
                        raise RuntimeError("OpenAI login page did not expose a continue button.")
                    email_submitted = True
                    page.wait_for_timeout(700)

                password_field = first_visible(page, [
                    "input[type='password']",
                    "input[name='password']",
                    "input[autocomplete='current-password']",
                ])
                if password_field is not None and not password_submitted:
                    password_field.fill(password)
                    if not click_continue(page):
                        raise RuntimeError("OpenAI login page did not expose a continue button.")
                    password_submitted = True
                    page.wait_for_timeout(700)

                otp_field = first_visible(page, [
                    "input[autocomplete='one-time-code']",
                    "input[name*='otp' i]",
                    "input[name*='authenticator' i]",
                ])
                if otp_field is not None and time.time() - otp_submitted_at > 25:
                    if not otp_secret:
                        raise RuntimeError("OpenAI requested an authenticator code but no TOTP secret was configured.")
                    fill_otp(otp_field, page, totp(otp_secret))
                    if not click_continue(page):
                        raise RuntimeError("OpenAI authenticator page did not expose a continue button.")
                    otp_submitted_at = time.time()
                    page.wait_for_timeout(700)

                text = body_text(page).lower()
                if any(phrase in text for phrase in (
                    "performing security verification",
                    "security service to protect against malicious bots",
                    "this page is displayed while the website verifies",
                )):
                    if not show_browser:
                        raise RuntimeError("OpenAI blocked unattended sign-in at its security verification page; automated sign-in stopped.")
                    if security_challenge_started is None:
                        security_challenge_started = time.time()
                    elif time.time() - security_challenge_started > 180:
                        raise RuntimeError("OpenAI security verification was not completed in the visible Deck sign-in window.")
                    page.wait_for_timeout(500)
                    continue
                security_challenge_started = None
                consent_step = any(phrase in text for phrase in (
                    "select a workspace",
                    "choose a workspace",
                    "authorize codex",
                    "codex would like to access",
                    "enable device code sign-in",
                ))
                identity_submitted = password_submitted or otp_submitted_at > 0
                consent_button = first_visible(page, [
                    "button:has-text('Authorize')",
                    "button:has-text('Approve')",
                    "button:has-text('Allow')",
                    "button:has-text('Continue')",
                    "button:has-text('Confirm')",
                ]) if identity_submitted and consent_step and not consent_clicked else None
                if consent_button is not None:
                    consent_button.click()
                    consent_clicked = True
                    page.wait_for_timeout(500)

                if any(phrase in text for phrase in (
                    "you can close this tab",
                    "you can close this window",
                    "return to codex",
                    "device authorized",
                    "successfully authorized",
                )):
                    return True
                if "chatgpt.com/codex/open-app" in page.url.lower():
                    return True
                parsed_url = urlparse(page.url)
                if parsed_url.hostname in ("127.0.0.1", "localhost") and parsed_url.path.endswith("/auth/callback"):
                    return True
                if any(word in text for word in (
                    "invalid password",
                    "incorrect password",
                    "wrong code",
                    "too many attempts",
                    "verify you are human",
                    "checking your browser",
                    "just a moment...",
                    "unusual activity",
                )):
                    raise RuntimeError("OpenAI required an interactive verification step; automated sign-in stopped.")
                has_visible_controls = bool(page.locator("input, button, [role=button]").count())
                if not email_submitted and not password_submitted and not has_visible_controls and time.time() - started_at > 15:
                    diagnostic = safe_page_diagnostics(page, email)
                    raise RuntimeError(f"OpenAI login form did not appear; page state: {diagnostic}")
                page.wait_for_timeout(500)

            step = "workspace consent" if password_submitted or otp_submitted_at else "account credentials"
            diagnostic = safe_page_diagnostics(page, email)
            raise RuntimeError(f"OpenAI sign-in timed out during {step}; page state: {diagnostic}")
    finally:
        if context is not None:
            try:
                context.close()
            except Exception:
                pass
        hide_stop.set()
        if hide_thread is not None:
            hide_thread.join(timeout=1)
        shutil.rmtree(temp_profile, ignore_errors=True)


def main():
    payload = json.load(sys.stdin)
    state = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    callback_server = None
    server_thread = None
    try:
        callback_server = OAuthCallbackServer(state)
        server_thread = threading.Thread(target=callback_server.serve_forever, daemon=True)
        server_thread.start()
        payload["verification_url"], redirect_uri = oauth_authorization_url(callback_server, verifier, state)
        if payload.get("browser_harness"):
            bridge_path = payload.get("bridge_path")
            if not bridge_path:
                raise RuntimeError("Deck could not publish the Chrome sign-in URL.")
            bridge_tmp = bridge_path + ".tmp"
            try:
                with open(bridge_tmp, "x", encoding="utf-8") as output:
                    json.dump({"url": payload["verification_url"]}, output)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(bridge_tmp, bridge_path)
            finally:
                try:
                    os.remove(bridge_tmp)
                except OSError:
                    pass
            if not callback_server.callback_event.wait(300):
                raise RuntimeError("Chrome sign-in timed out before Deck received the OAuth callback.")
        else:
            complete_login(payload)
        if not callback_server.callback_event.wait(5):
            raise RuntimeError("Deck did not receive the OAuth callback.")
        if callback_server.error:
            raise RuntimeError(callback_server.error)
        token_result = exchange_oauth_code(callback_server.code, redirect_uri, verifier)
        save_codex_auth(payload["codex_home"], token_result, payload["email"])
    except Exception as error:
        print(str(error), file=sys.stderr)
        return 1
    finally:
        if callback_server is not None:
            callback_server.shutdown()
            callback_server.server_close()
        if server_thread is not None:
            server_thread.join(timeout=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
