class CryptoHelper {
    python: string,
    path: string,
    function call(self, request: json) -> json {
        let out = baml.sys.exec(
            self.python,
            [self.path],
            baml.sys.ProcessOptions {
                cwd: null,
                env: null,
                timeout_ms: 5000,
                stdin: baml.json.stringify(request),
                stderr: baml.sys.StderrMode.Pipe,
            },
        );
        require(out.exit_code == 0, 401, "invalid_signature");
        baml.json.parse(out.stdout.to_string())
    }
    function sign(self, app_id: string, key: string) -> string {
        str(self.call({ "operation": "sign", "app_id": app_id, "key": key }), "token")
    }
    function verify(self, token: string, jwks: json, issuer: string, audience: string) -> json {
        field(
            self.call(
                {
                    "operation": "verify",
                    "token": token,
                    "jwks": jwks,
                    "issuer": issuer,
                    "audience": audience,
                },
            ),
            "claims",
        )
    }
}

interface Transport {
    function send(
        self,
        method: string,
        url: string,
        token: string,
        payload: json,
    ) -> json throws unknown;
}

class HttpTransport {
    implements Transport {
        function send(self, method: string, url: string, token: string, payload: json) -> json {
            let req = baml.http.Request.from_url(url)
                .set_method(method)
                .set_timeout(baml.time.Duration.from_seconds(15))
                .set_headers(
                    {
                        "authorization": "Bearer " + token,
                        "content-type": "application/json",
                        "accept": "application/json",
                        "user-agent": "CodeTurtle/0.1",
                        "x-github-api-version": "2022-11-28",
                    },
                );
            if (payload != null) {
                req.set_body(baml.json.stringify(payload));
            }
            let r = baml.http.send(req);
            require(
                r.status_code >= 200 && r.status_code < 300,
                if (r.status_code == 429 || r.status_code >= 500) {
                    503
                } else if (r.status_code == 404) {
                    404
                } else {
                    502
                },
                "provider_request_failed",
            );
            baml.json.parse(r.text())
        }
    }
}

class GitHubOIDC {
    crypto: CryptoHelper,
    http: Transport,
    audience: string,
    function verify(self, token: string, identity: RunIdentity) -> json {
        let jwks = self.http.send(
            "GET",
            "https://token.actions.githubusercontent.com/.well-known/jwks",
            "",
            null,
        );
        let claims = self.crypto.verify(
            token,
            jwks,
            "https://token.actions.githubusercontent.com",
            self.audience,
        );
        validate_ci_claims(claims, identity);
        claims
    }
}

function validate_ci_claims(c: json, i: RunIdentity) -> void {
    require(
        str(c, "repository_id") == i.repository_id
            && str(c, "repository") == i.repository
            && str(c, "run_id") == i.run_id
            && str(c, "run_attempt") == i.run_attempt.to_string(),
        403,
        "claim_identity_mismatch",
    );
    require(
        str(c, "event_name") == "pull_request_target"
            && str(c, "runner_environment") == "github-hosted"
            && str(c, "sha") == i.base,
        403,
        "untrusted_execution",
    );
}

class BrowserAuth {
    store: RunStore,
    http: Transport,
    origin: string,
    client_id: string,
    client_secret: string,
    secrets: SecretBox,
    function login(self, req: baml.http.ServerRequest) -> baml.http.Response {
        let state = secret();
        let next = safe_return(query(req.url).get("next") ?? "/");
        let _ = self.store.rpc(
            "oauth_put",
            {
                "hash": sha256(state),
                "purpose": "workos",
                "data": { "next": next },
                "expires_at": now() + 600,
            },
        );
        redirect(
            "https://api.workos.com/user_management/authorize?provider=authkit&response_type=code&client_id="
                + url_encode(self.client_id)
                + "&redirect_uri="
                + url_encode(self.origin + "/auth/callback")
                + "&state="
                + state,
            set_cookie = "__Host-ct_login=" + state + "; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=600",
        )
    }
    function complete_login(self, req: baml.http.ServerRequest) -> baml.http.Response {
        let q = query(req.url);
        let state = q.get("state") ?? "";
        require(
            state.length() == 64 && cookie(req, "__Host-ct_login") == state,
            403,
            "invalid_login_state",
        );
        let login_data = self.store.rpc("oauth_take", { "hash": sha256(state), "purpose": "workos" });
        let result = self.http.send(
            "POST",
            "https://api.workos.com/user_management/authenticate",
            "",
            {
                "client_id": self.client_id,
                "client_secret": self.client_secret,
                "grant_type": "authorization_code",
                "code": q.get("code") ?? "",
            },
        );
        let user = field(result, "user");
        require(field(user, "email_verified") == true, 403, "verified_identity_required");
        let actor = Actor { user_id: str(user, "id"), tenant_id: str(result, "organization_id") };
        let token = secret();
        let _ = self.store.rpc(
            "session_put",
            {
                "token_hash": sha256(token),
                "actor": baml.json.from(actor),
                "csrf": secret(),
                "expires_at": now() + 3600,
            },
        );
        redirect(
            safe_return(baml.json.to<string?>(field(login_data, "next")) ?? "/"),
            set_cookie = "__Host-ct_session=" + token + "; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=3600",
        )
    }
    function session(self, req: baml.http.ServerRequest, mutation: bool = false) -> json {
        let token = cookie(req, "__Host-ct_session");
        require(token.length() == 64, 401, "login_required");
        let session = self.store.rpc("session_get", { "token_hash": sha256(token) });
        if (mutation) {
            require(
                req.headers.get("origin") == self.origin
                    && req.headers.get("x-csrf-token") == str(session, "csrf"),
                403,
                "csrf_required",
            );
        }
        session
    }
    function authorize(
        self,
        req: baml.http.ServerRequest,
        repository_id: string,
        setup: bool = false,
    ) -> Actor {
        let actor = baml.json.to<Actor>(field(self.session(req, mutation = setup), "actor"));
        let membership = self.store.rpc(
            "authorize",
            { "actor": baml.json.from(actor), "repository_id": repository_id, "setup": setup },
        );
        let enrolled = self.store.enrollment(repository_id);
        let token = self.secrets.open(
            str(membership, "encrypted_token"),
            "github-user:" + actor.user_id + ":" + repository_id,
        );
        let repo = self.http.send("GET", "https://api.github.com/repos/" + enrolled.repository, token, null);
        require(
            num(repo, "id").to_string() == repository_id
                && (
                    if (setup) {
                        field(field(repo, "permissions"), "admin") == true
                    } else {
                        field(field(repo, "permissions"), "pull") == true
                    }
                ),
            403,
            "repository_access_revoked",
        );
        actor
    }
}

function cookie(req: baml.http.ServerRequest, name: string) -> string {
    for (let item in (req.headers.get("cookie") ?? "").split(";")) {
        let p = item.trim().split("=");
        if (p.length() == 2 && p[0] == name) {
            return p[1];
        }
    }
    ""
}

function url_encode(value: string) -> string {
    let result = "";
    for (let b in value.to_utf8().to_array()) {
        if (
            (b >= 65 && b <= 90)
                || (b >= 97 && b <= 122)
                || (b >= 48 && b <= 57)
                || [45, 46, 95, 126].includes(b)
        ) {
            result += string.from_code_points([b]);
        } else {
            result += "%" + uint8array.from_array([b]).to_hex().to_upper_case();
        }
    }
    result
}

function url_decode(value: string) -> string {
    let bytes = uint8array.zeroes(0);
    let pos = 0;
    let raw = value.replace_all("+", " ").to_utf8();
    while (pos < raw.length()) {
        if (raw[pos] == 37) {
            require(pos + 2 < raw.length(), 400, "invalid_query");
            bytes = bytes.concat(uint8array.from_hex(raw.slice(pos + 1, pos + 3).to_string()));
            pos += 3;
        } else {
            bytes.push(raw[pos]);
            pos += 1;
        }
    }
    string.from_utf8(bytes)
}

function query(url: string) -> map<string, string> {
    let result: map<string, string> = {};
    let q = url.split("?").at(1) ?? "";
    for (let part in q.split("&")) {
        let p = part.split("=");
        if (p.length() == 2) {
            let key = url_decode(p[0]);
            require(result.get(key) == null, 400, "duplicate_query_parameter");
            result[key] = url_decode(p[1]);
        }
    }
    result
}

function redirect(location: string, set_cookie: string = "") -> baml.http.Response {
    let headers = { "location": location, "cache-control": "no-store", "referrer-policy": "no-referrer" };
    if (set_cookie != "") {
        headers["set-cookie"] = set_cookie;
    }
    baml.http.Response.new(302, headers, b"")
}

test "URL roundtrip and cookie parsing" {
    assert.equal(url_decode(url_encode("a /?&=%é")), "a /?&=%é");
    assert.equal(query("/?code=a%3Db&state=42").get("code"), "a=b")
}

function safe_return(path: string) -> string {
    if (
        path == "/"
            || (
                path.starts_with("/?")
                    && !path.includes("\n")
                    && !path.includes("\r")
                    && !path.includes("\\")
            )
    ) {
        path
    } else {
        "/"
    }
}
