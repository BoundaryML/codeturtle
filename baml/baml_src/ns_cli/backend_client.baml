// Hosted-mode backend client: Actions OIDC registration, immutable
// report upload with idempotent retries, and credential renewal.
// Endpoints per the product spec HTTP table.

class ActionsContext {
    repository: string,
    pr_number: int,
    run_id: string,
    run_attempt: string,
    event_name: string,
    head_sha: string,

    function from_env() -> ActionsContext throws root.CliError {
        let unsupported = root.ErrorCode.UnsupportedExecutionContext;
        if (root.lib.env.env_or_null("GITHUB_ACTIONS") != "true") {
            throw root.CliError.new(unsupported, "--backend requires GitHub Actions");
        }
        let event_name = root.lib.env.env_required("GITHUB_EVENT_NAME", unsupported);
        if (event_name != "pull_request" && event_name != "pull_request_target") {
            throw root.CliError.new(unsupported, `unsupported Actions event "${event_name}"`);
        }
        let ref = root.lib.env.env_required("GITHUB_REF", unsupported);
        let pr_number = match (ActionsContext.pr_number_from_ref(ref)) {
            null => throw root.CliError.new(unsupported, `cannot determine PR from ref "${ref}"`),
            let n: int => n,
        };
        ActionsContext {
            repository: root.lib.env.env_required("GITHUB_REPOSITORY", unsupported),
            pr_number: pr_number,
            run_id: root.lib.env.env_required("GITHUB_RUN_ID", unsupported),
            run_attempt: root.lib.env.env_or_null("GITHUB_RUN_ATTEMPT") ?? "1",
            event_name: event_name,
            head_sha: root.lib.env.env_required("GITHUB_SHA", unsupported),
        }
    }

    function pr_number_from_ref(ref: string) -> int? {
        let parts = ref.split("/");
        if (parts.length() >= 4 && parts[0] == "refs" && parts[1] == "pull") {
            root.lib.text.Text.parse_int_or_null(parts[2])
        } else {
            null
        }
    }
}

class OidcResponse {
    value: string,
}

class RegisterPayload {
    repository: string,
    pr_number: int,
    run_id: string,
    run_attempt: string,
    head_sha: string,
}

class BackendErrorBody {
    code: string?,
    message: string?,
    retryable: bool?,

    function decode(text: string) -> BackendErrorBody {
        let empty = BackendErrorBody { code: null, message: null, retryable: null };
        baml.json.from_string<BackendErrorBody>(text) catch (e) {
            baml.json.ParseError => empty,
            baml.json.DecodeError => empty,
        }
    }

    // The body's spec code wins; the HTTP status is the fallback.
    function error_code(self, status: int) -> root.ErrorCode {
        match (self.code) {
            "repository_not_enrolled" => root.ErrorCode.RepositoryNotEnrolled,
            "untrusted_workflow" => root.ErrorCode.UntrustedWorkflow,
            "identity_rejected" => root.ErrorCode.IdentityRejected,
            "report_conflict" => root.ErrorCode.ReportConflict,
            "report_rejected" => root.ErrorCode.ReportRejected,
            "stale_evaluation" => root.ErrorCode.StaleEvaluation,
            "pull_request_closed" => root.ErrorCode.PullRequestClosed,
            _ => match (status) {
                401 => root.ErrorCode.IdentityRejected,
                403 => root.ErrorCode.IdentityRejected,
                404 => root.ErrorCode.RepositoryNotEnrolled,
                409 => root.ErrorCode.ReportConflict,
                410 => root.ErrorCode.PullRequestClosed,
                422 => root.ErrorCode.ReportRejected,
                _ => root.ErrorCode.BackendUnavailable,
            },
        }
    }
}

class HttpResult {
    status: int,
    body: string,

    function request(
        method: string,
        url: string,
        token: string?,
        body: string,
        idempotency_key: string?,
    ) -> baml.http.Request {
        let headers: map<string, string> = { "content-type": "application/json" };
        match (token) {
            null => null,
            let t: string => {
                headers["authorization"] = `Bearer ${t}`;
                null
            },
        };
        match (idempotency_key) {
            null => null,
            let key: string => {
                headers["idempotency-key"] = key;
                null
            },
        };
        let timeout = baml.time.Duration.from_seconds(root.lib.limits.Limits.http_timeout_seconds());
        baml.http.Request {
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeout: timeout,
            connect_timeout: timeout,
        }
    }

    // Sends with bounded retries: transport failures and retryable
    // statuses back off and retry; the last attempt's result is returned
    // (or its error thrown) as is.
    function send(request: baml.http.Request) -> HttpResult throws root.CliError {
        HttpResult._send_attempt(request, 0)
    }

    function _send_attempt(
        request: baml.http.Request,
        attempt: int,
    ) -> HttpResult throws root.CliError {
        let retries_left = attempt + 1 < root.lib.limits.Limits.upload_max_attempts();
        let result = HttpResult._send_once(request) catch (e) {
            root.CliError => {
                if (retries_left && e.code == root.ErrorCode.BackendUnavailable) {
                    null
                } else {
                    throw e
                }
            },
        };
        match (result) {
            null => HttpResult._retry(request, attempt),
            let r: HttpResult => {
                if (retries_left && r.is_retryable()) {
                    HttpResult._retry(request, attempt)
                } else {
                    r
                }
            },
        }
    }

    function _retry(request: baml.http.Request, attempt: int) -> HttpResult throws root.CliError {
        baml.sys.sleep(baml.time.Duration.from_milliseconds(250 * (attempt + 1)));
        HttpResult._send_attempt(request, attempt + 1)
    }

    function _send_once(request: baml.http.Request) -> HttpResult throws root.CliError {
        let response = baml.http.send(request) catch (e) {
            baml.errors.Io => {
                throw root.CliError.new(root.ErrorCode.BackendUnavailable, `backend request failed: ${e.message}`)
            },
            baml.errors.Timeout => {
                throw root.CliError.new(root.ErrorCode.BackendUnavailable, "backend request timed out")
            },
            baml.errors.InvalidArgument => {
                throw root.CliError.new(root.ErrorCode.InvalidBackendUrl, `invalid backend request: ${e.message}`)
            },
        };
        let body = response.text() catch (e) {
            baml.errors.Io => "",
            baml.errors.Timeout => "",
        };
        HttpResult { status: response.status_code, body: body }
    }

    function is_retryable(self) -> bool {
        self.status == 408 || self.status == 429 || self.status >= 500
    }

    // The body of a 2xx response; otherwise throws the backend's error,
    // using `what` to describe the request when the body has no message.
    function success_body(self, what: string) -> string throws root.CliError {
        if (self.status >= 200 && self.status < 300) {
            return self.body;
        }
        let error = BackendErrorBody.decode(self.body);
        throw root.CliError.new(
            error.error_code(self.status),
            error.message ?? `${what} failed with status ${self.status}`,
        );
    }
}

class BackendClient {
    backend: root.lib.url.Url,
    oidc_token: string,

    function connect(backend: root.lib.url.Url) -> BackendClient throws root.CliError {
        BackendClient { backend: backend, oidc_token: BackendClient._fetch_oidc_token() }
    }

    function _fetch_oidc_token() -> string throws root.CliError {
        let rejected = root.ErrorCode.IdentityRejected;
        let request_url = root.lib.env.env_required("ACTIONS_ID_TOKEN_REQUEST_URL", rejected);
        let request_token = root.lib.env.env_required("ACTIONS_ID_TOKEN_REQUEST_TOKEN", rejected);
        let separator = if (request_url.includes("?")) {
            "&"
        } else {
            "?"
        };
        let url = `${request_url}${separator}audience=codeturtle`;
        let body = HttpResult.send(HttpResult.request("GET", url, request_token, "", null)).success_body(
            "OIDC token request",
        );
        let parsed = baml.json.from_string<OidcResponse>(body) catch (e) {
            baml.json.ParseError => {
                throw root.CliError.new(rejected, "OIDC response is not valid JSON")
            },
            baml.json.DecodeError => {
                throw root.CliError.new(rejected, "OIDC response has an unexpected shape")
            },
        };
        parsed.value
    }

    function _url(self, path: string) -> string throws root.CliError {
        let joined = self.backend.join(path) catch (e) {
            root.lib.url.UrlParseError => {
                throw root.CliError.new(root.ErrorCode.InvalidBackendUrl, e.message)
            },
        };
        joined.as_str()
    }

    function register(self, ctx: ActionsContext) -> root.RegisterResponse throws root.CliError {
        let payload = baml.json.to_string(
            RegisterPayload {
                repository: ctx.repository,
                pr_number: ctx.pr_number,
                run_id: ctx.run_id,
                run_attempt: ctx.run_attempt,
                head_sha: ctx.head_sha,
            },
        ) catch (e) {
            baml.json.SerializationError => {
                throw root.CliError.new(root.ErrorCode.BackendUnavailable, `cannot serialize registration: ${e.message}`)
            },
        };
        let request = HttpResult.request(
            "POST",
            self._url("/v1/evaluation-attempts"),
            self.oidc_token,
            payload,
            null,
        );
        let body = HttpResult.send(request).success_body("registration");
        baml.json.from_string<root.RegisterResponse>(body) catch (e) {
            baml.json.ParseError => {
                throw root.CliError.new(root.ErrorCode.ReportRejected, "registration response is not valid JSON")
            },
            baml.json.DecodeError => {
                throw root.CliError.new(root.ErrorCode.ReportRejected, `registration response has an unexpected shape: ${e.message}`)
            },
        }
    }

    function renew_credentials(self, attempt_id: string) -> string throws root.CliError {
        let url = self._url(`/v1/evaluation-attempts/${attempt_id}/credentials`);
        let body = HttpResult.send(HttpResult.request("POST", url, self.oidc_token, "{}", null)).success_body(
            "credential renewal",
        );
        let parsed = baml.json.from_string<root.CredentialsResponse>(body) catch (e) {
            baml.json.ParseError => {
                throw root.CliError.new(root.ErrorCode.ReportRejected, "credential response is not valid JSON")
            },
            baml.json.DecodeError => {
                throw root.CliError.new(root.ErrorCode.ReportRejected, "credential response has an unexpected shape")
            },
        };
        parsed.upload_token
    }

    // Uploads with the registration's upload token, renewing it once on
    // 401. The attempt id doubles as the idempotency key.
    function upload(
        self,
        registration: root.RegisterResponse,
        report_json: string,
    ) -> root.UploadResponse throws root.CliError {
        let url = self._url(`/v1/evaluation-attempts/${registration.attempt_id}/report`);
        let put = (token: string) -> HttpResult throws root.CliError {
            HttpResult.send(
                HttpResult.request("PUT", url, token, report_json, registration.attempt_id),
            )
        };
        let first = put(registration.upload_token);
        let result = match (first.status) {
            401 => put(self.renew_credentials(registration.attempt_id)),
            _ => first,
        };
        let body = result.success_body("report upload");
        let fallback = root.UploadResponse { evaluation_id: registration.evaluation_id, review_url: null };
        baml.json.from_string<root.UploadResponse>(body) catch (e) {
            baml.json.ParseError => fallback,
            baml.json.DecodeError => fallback,
        }
    }
}

test "backend error codes map from body first" {
    let code = (body_code: string?, status: int) -> root.ErrorCode {
        BackendErrorBody { code: body_code, message: null, retryable: null }.error_code(status)
    };
    assert.equal(code("stale_evaluation", 500), root.ErrorCode.StaleEvaluation);
    assert.equal(code(null, 422), root.ErrorCode.ReportRejected);
    assert.equal(ActionsContext.pr_number_from_ref("refs/pull/42/merge"), 42);
    assert.equal(ActionsContext.pr_number_from_ref("refs/heads/main"), null)
}
