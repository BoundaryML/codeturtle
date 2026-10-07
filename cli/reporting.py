"""Internal Actions identity exchange and durable report upload (stdlib only)."""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

VERSION = "0.1.0"
LIMIT = 4 * 1024 * 1024


class ReportingError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def checked_url(url, test_mode=False):
    p = urllib.parse.urlsplit(url)
    try:
        loopback = ipaddress.ip_address(p.hostname or "").is_loopback
    except ValueError:
        loopback = False
    if (p.scheme != "https" and not (test_mode and p.scheme == "http" and loopback)) or not p.hostname or p.username or p.password or p.fragment:
        raise ReportingError("Reporting requires an HTTPS URL without credentials or fragments")
    return url


def request_json(url, method, token, body=None, expected=(200,), test_mode=False):
    checked_url(url, test_mode)
    if body is not None and len(body) > LIMIT:
        raise ReportingError("Report exceeds the upload limit")
    for attempt in range(4):
        try:
            request = urllib.request.Request(url, data=body, method=method, headers={
                "Authorization": "Bearer " + token, "Content-Type": "application/json", "Accept": "application/json",
            })
            with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
                if response.status not in expected:
                    raise ReportingError("Unexpected service response")
                data = response.read(LIMIT + 1)
                if len(data) > LIMIT:
                    raise ReportingError("Service response exceeds limit")
                result = json.loads(data)
                if not isinstance(result, dict):
                    raise ReportingError("Invalid service response")
                return result
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            if status not in (408, 429, 500, 502, 503, 504):
                raise ReportingError(f"Reporting request rejected (HTTP {status})", status=status) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            pass
        except (ValueError, UnicodeError):
            raise ReportingError("Invalid service JSON response") from None
        if attempt < 3:
            time.sleep(0.5 * 2 ** attempt)
    raise ReportingError("Reporting service unavailable after bounded retries")


def ci_context(environment):
    try:
        if environment.get("GITHUB_ACTIONS") != "true" or environment["GITHUB_EVENT_NAME"] != "pull_request_target":
            raise ValueError()
        event = json.loads(Path(environment["GITHUB_EVENT_PATH"]).read_text())
        pr, repo = event["pull_request"], event["repository"]
        if str(repo["id"]) != environment["GITHUB_REPOSITORY_ID"] or repo["full_name"] != environment["GITHUB_REPOSITORY"] or pr["base"]["repo"]["id"] != repo["id"]:
            raise ValueError()
        identity = {"repository_id": str(repo["id"]), "repository": repo["full_name"],
                    "pr": pr["number"], "run_id": environment["GITHUB_RUN_ID"],
                    "run_attempt": int(environment["GITHUB_RUN_ATTEMPT"]),
                    "head": pr["head"]["sha"], "base": pr["base"]["sha"], "policy": pr["base"]["sha"]}
        if identity["pr"] <= 0 or identity["run_attempt"] <= 0 or not identity["run_id"].isdigit() or not identity["repository_id"].isdigit():
            raise ValueError()
        if not all(re.fullmatch(r"[0-9a-f]{40}", identity[k]) for k in ("head", "base", "policy")):
            raise ValueError()
        return identity
    except (KeyError, ValueError, TypeError, OSError):
        raise ReportingError("Reporting requires a valid trusted pull_request_target Actions context") from None


class Reporter:
    def __init__(self, environment=None):
        self.env = dict(os.environ if environment is None else environment)
        self.test_mode = self.env.get("CODETURTLE_TEST_LOOPBACK") == "1"
        self.origin = checked_url(self.env.get("CODETURTLE_API_URL", ""), self.test_mode).rstrip("/")
        if urllib.parse.urlsplit(self.origin).path or urllib.parse.urlsplit(self.origin).query:
            raise ReportingError("CODETURTLE_API_URL must be an origin")
        self.identity = ci_context(self.env)
        self.grant = None
        self.payload = None

    def request(self, url, method, token, body=None, expected=(200,)):
        return request_json(url, method, token, body, expected, self.test_mode)

    def register(self):
        try:
            oidc_url = self.env["ACTIONS_ID_TOKEN_REQUEST_URL"]
            p = urllib.parse.urlsplit(checked_url(oidc_url, self.test_mode))
            if not self.test_mode and not (p.hostname or "").endswith(".actions.githubusercontent.com"):
                raise ReportingError("Unexpected Actions identity endpoint")
            query = [(k, v) for k, v in urllib.parse.parse_qsl(p.query) if k != "audience"]
            query.append(("audience", self.origin))
            oidc = self.request(urllib.parse.urlunsplit(p._replace(query=urllib.parse.urlencode(query))), "GET", self.env["ACTIONS_ID_TOKEN_REQUEST_TOKEN"])
            grant = self.request(self.origin + "/v1/runs", "POST", oidc["value"], json.dumps(self.identity).encode(), (200, 201))
            if grant["identity"] != self.identity or not re.fullmatch(r"[a-f0-9-]{36}", grant["run_id"]) or not isinstance(grant["token"], str) or len(grant["token"]) < 32:
                raise ValueError()
            if not time.time() < grant["expires_at"] <= time.time() + 960 or not re.fullmatch(r"[a-f0-9]{40}", grant["merge_base"]) or not isinstance(grant["title"], str):
                raise ValueError()
            if self.grant and any(grant[k] != self.grant[k] for k in ("run_id", "identity", "merge_base", "title")):
                raise ReportingError("Run inputs changed during grant renewal")
            self.grant = grant
            return grant
        except (KeyError, ValueError, TypeError):
            raise ReportingError("Invalid run grant or Actions identity configuration") from None

    def upload(self, report=None, setup_failure=None):
        if not self.grant or self.grant["expires_at"] < time.time() + 60:
            self.register()
        if (report is None) == (setup_failure is None):
            raise ReportingError("Exactly one report or setup failure is required")
        envelope = {"schema_version": 1, "cli_version": VERSION, "run_id": self.grant["run_id"],
                    "identity": self.identity, "report": report,
                    "setup_failure": {"code": "evaluation_setup_failed", "message": "CLI could not complete setup; see CI logs"} if setup_failure else None}
        payload = json.dumps(envelope, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
        if self.payload is not None and self.payload != payload:
            raise ReportingError("Cannot change an upload during retry")
        self.payload = payload
        url = self.origin + "/v1/runs/" + self.grant["run_id"]
        try:
            receipt = self.request(url + "/report", "PUT", self.grant["token"], payload, (202,))
        except ReportingError as error:
            if error.status != 401:
                raise
            self.register()
            receipt = self.request(url + "/report", "PUT", self.grant["token"], payload, (202,))
        if receipt.get("run_id") != self.grant["run_id"] or receipt.get("digest") != hashlib.sha256(payload).hexdigest() or receipt.get("status_url") != url or not receipt.get("accepted_at"):
            raise ReportingError("Invalid durable acceptance receipt")
        return receipt
