class ReportService {
    store: RunStore,
    github: GitHubClient,
    oidc: GitHubOIDC,
    parser: ReportParser,
    origin: string,
    slack: SlackClient,
    browser: BrowserAuth?,
    onboarding: Onboarding?,
    function register(self, request: baml.http.ServerRequest) -> baml.http.Response {
        let identity = baml.json.from_string<RunIdentity>(request.body);
        validate_identity(identity);
        let claims = self.oidc.verify(bearer(request), identity);
        let enrolled = self.store.enrollment(identity.repository_id);
        if (enrolled.workflow_blob == "") {
            require(enrolled.active && enrolled.repository == identity.repository
                && str(claims, "workflow_ref") == enrolled.workflow_ref
                && str(claims, "workflow_sha") == identity.base, 403, "untrusted_workflow");
            if let onboarding: Onboarding = self.onboarding {
                let _ = onboarding.activate_setup(identity.repository_id);
                enrolled = self.store.enrollment(identity.repository_id);
            }
        }
        let authorized = self.github.authorize(identity, claims, enrolled);
        let token = secret();
        let stored = self.store.register(authorized, sha256(token), now() + 900);
        response(
            200,
            baml.json.from(
                RunGrant {
                    run_id: stored.id,
                    token: token,
                    expires_at: stored.expires_at,
                    identity: stored.authorized.identity,
                    merge_base: stored.authorized.merge_base,
                    title: stored.authorized.title,
                },
            ),
        )
    }
    function upload(self, id: string, request: baml.http.ServerRequest) -> baml.http.Response {
        let token_hash = sha256(bearer(request));
        let stored = self.store.lookup(id, token_hash);
        let digest = sha256(request.body);
        if (stored.digest != null) {
            require(stored.digest == digest, 409, "conflicting_report");
            return self.receipt(stored);
        }
        let envelope = baml.json.from_string<ReportEnvelope>(request.body);
        validate_envelope(envelope, stored, self.parser);
        let pr = self.github.current_pr(stored.authorized.identity, self.github.installation_token(stored.authorized.enrollment));
        //# Receipt follows the durable report/outbox transaction.
        let accepted = self.store.accept(id, token_hash, digest, envelope);
        trace_review_report(accepted, str(field(pr, "user"), "login")) catch_all (_) { _ => log.warn("Review telemetry unavailable") };
        self.receipt(accepted)
    }
    function receipt(self, run: StoredRun) -> baml.http.Response {
        response(
            202,
            baml.json.from(
                Receipt {
                    run_id: run.id,
                    digest: run.digest ?? throw "Missing digest",
                    accepted_at: run.accepted_at ?? throw "Missing acceptance",
                    status_url: self.origin + "/v1/runs/" + run.id,
                },
            ),
        )
    }
    function handle(self, req: baml.http.ServerRequest) -> baml.http.Response {
        let started = baml.time.Instant.now();
        let timing = RequestTiming {gate:(baml.spawn.Limit.new(1) catch_all (_) { _ => baml.sys.panic("Invalid timing limit") }), durations:{}, counts:{}};
        let store = TimedStore {inner:self.store, timing:timing};
        let http = TimedTransport {inner:self.github.http, timing:timing};
        let github = GitHubClient {...self.github, http:http};
        let browser = if let auth: BrowserAuth = self.browser { BrowserAuth {...auth, store:store, http:TimedTransport {inner:auth.http,timing:timing}} } else {null};
        let request = ReportService {...self, store:store, github:github, browser:browser};
        let result = request.route(req) catch_all (error, context) {
            let e: ApiError => response(e.status, { "error": e.code }),
            baml.json.ParseError | baml.json.DecodeError => {
                response(400, { "error": "invalid_json" })
            },
            _ => {
                log.error("Request failed at " + context.stack_trace.to_string());
                response(503, { "error": "service_unavailable" })
            },
        };
        result.headers["server-timing"] = "total;dur=" + started.elapsed().to_milliseconds().to_string() + ", " + timing.header();
        result
    }
    function route(self, req: baml.http.ServerRequest) -> baml.http.Response {
        require(req.body.to_utf8().length() <= 4194304, 413, "payload_too_large");
        require(!req.body.includes("�"), 400, "invalid_utf8");
        let route = req.url.split("?")[0];
        if (route == "/webhooks/github" && req.method == "POST") {
            let result = receive_webhook(req, self.store, config("CODETURTLE_GITHUB_WEBHOOK_SECRET"));
            let event = req.headers.get("x-github-event") ?? "";
            if (event == "pull_request") { invalidate_bot_review(self.github, self.store, baml.json.parse(req.body)); }
            if (event == "installation" || event == "installation_repositories") { self.github.tokens.clear(); }
            return result;
        }
        if let browser: BrowserAuth = self.browser {
            if (route == "/auth/logout" && req.method == "POST") {
                let _ = browser.session(req, mutation = true);
                let _ = self.store.rpc("session_revoke", {"token_hash": sha256(cookie(req, "__Host-ct_session"))});
                let result = response(200, {"signed_out": true});
                result.headers["set-cookie"] = "__Host-ct_session=; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=0";
                return result;
            }
            if (route == "/auth/login" && req.method == "GET") {
                return browser.login(req);
            }
            if (route == "/auth/callback" && req.method == "GET") {
                return browser.complete_login(req);
            }
            if (route == "/auth/github/start" && req.method == "GET") {
                return start_setup(browser, req, config("CODETURTLE_GITHUB_CLIENT_ID"));
            }
            if (route == "/auth/github/callback" && req.method == "GET") {
                return complete_setup(
                    browser,
                    req,
                    self.github,
                    self.slack.secrets,
                    config("CODETURTLE_GITHUB_CLIENT_ID"),
                    config("CODETURTLE_GITHUB_CLIENT_SECRET"),
                );
            }
            if (route == "/auth/slack/start" && req.method == "GET") {
                return start_slack(
                    browser,
                    req,
                    query(req.url).get("repository_id") ?? "",
                    config("CODETURTLE_SLACK_CLIENT_ID"),
                );
            }
            if (route == "/auth/slack/callback" && req.method == "GET") {
                return complete_install(
                    browser,
                    req,
                    self.slack,
                    config("CODETURTLE_SLACK_CLIENT_ID"),
                    config("CODETURTLE_SLACK_CLIENT_SECRET"),
                );
            }
            if (route == "/api/github/repositories" && (req.method == "GET" || req.method == "POST")) {
                return response(200, repository_picker(browser, req, self.github));
            }
            if (route == "/api/session" && req.method == "GET") {
                let session = browser.session(req);
                return response(
                    200,
                    {
                        "csrf": field(session, "csrf"),
                        "repositories": self.store.rpc("repositories", { "actor": field(session, "actor") }),
                    },
                );
            }
            if (route == "/api/workspace" && req.method == "GET") {
                return response(200, workspace_get(browser, req, self.github));
            }
            if (route == "/api/workspace" && req.method == "POST") {
                return response(200, workspace_write(browser, req, self.github));
            }
            if (route == "/api/workspace/content" && req.method == "GET") {
                return response(200, workspace_content(browser, req, self.github));
            }
            if (route == "/api/workspace/state" && req.method == "GET") {
                return response(200, workspace_state(browser, req));
            }
            if (route == "/api/workspace/comments" && req.method == "GET") {
                return response(200, workspace_comments(browser, req));
            }
            if (route == "/api/review" && req.method == "GET") {
                return response(200, review_page(browser, req, self.github));
            }
            if (route == "/api/review/diff" && req.method == "GET") {
                return response(200, review_diff(browser, req, self.github));
            }
            if (route == "/api/review/decision" && req.method == "POST") {
                return response(410, { "error": "use_workspace_submit" });
            }
            if (route == "/api/slack/mapping" && req.method == "POST") {
                let body = baml.json.parse(req.body);
                return response(
                    200,
                    link_owner(
                        browser,
                        req,
                        self.slack,
                        str(body, "repository_id"),
                        str(body, "owner"),
                        str(body, "user_id"),
                        str(body, "channel"),
                    ),
                );
            }
            if let onboarding: Onboarding = self.onboarding {
                if (route == "/api/setup" && req.method == "GET") {
                    return response(200, onboarding.verify_setup(req, query(req.url).get("repository_id") ?? ""));
                }
                if (route == "/api/setup" && req.method == "POST") {
                    let body = baml.json.parse(req.body);
                    return response(
                        200,
                        onboarding.create_setup_pr(
                            req,
                            str(body, "repository_id"),
                            baml.json.to<SetupOptions>(field(body, "options")),
                        ),
                    );
                }
            }
        }
        if (
            req.method == "GET"
                && (
                    ["/", "/codeturtle.svg"].includes(route)
                        || matches(route, "^/assets/[A-Za-z0-9_.-]+\\.(js|css|woff2?|ttf)$")
                )
        ) {
            let file = if (route == "/") {
                "index.html"
            } else {
                route.slice(1, route.length())
            };
            let mime = if (route == "/") {
                "text/html"
            } else if (route.ends_with(".js")) {
                "text/javascript"
            } else {
                if (route.ends_with(".css")) {
                    "text/css"
                } else if (route.ends_with(".svg")) {
                    "image/svg+xml"
                } else if (route.ends_with(".woff2")) {
                    "font/woff2"
                } else if (route.ends_with(".woff")) {
                    "font/woff"
                } else {
                    "font/ttf"
                }
            };
            return baml.http.Response.new(
                200,
                {
                    "content-type": mime,
                    "content-security-policy": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; worker-src 'self' blob:; font-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
                    "x-content-type-options": "nosniff",
                    "referrer-policy": "no-referrer",
                    "cache-control": if (route.starts_with("/assets/")) {
                        "public, max-age=31536000, immutable"
                    } else {
                        "no-store"
                    },
                },
                {
                    let asset = baml.fs.open(config("CODETURTLE_FRONTEND_DIR") + "/" + file, "r");
                    defer { asset.close(); }
                    asset.bytes()
                },
            );
        }
        if (req.method == "GET" && req.url == "/healthz") {
            return response(200, { "status": "alive" });
        }
        if (req.method == "GET" && req.url == "/readyz") {
            let _ = self.store.rpc("ready", {});
            return response(200, { "status": "ready" });
        }
        if (req.method == "POST" && req.url == "/v1/runs") {
            return self.register(req);
        }
        let parts = req.url.split("/");
        if (
            parts.length() >= 4
                && parts[1] == "v1"
                && parts[2] == "runs"
                && matches(parts[3], "^[a-f0-9-]{36}$")
        ) {
            if (parts.length() == 5 && parts[4] == "report" && req.method == "PUT") {
                return self.upload(parts[3], req);
            }
            if (parts.length() == 4 && req.method == "GET") {
                let r = self.store.lookup(parts[3], sha256(bearer(req)));
                return response(
                    200,
                    {
                        "run_id": r.id,
                        "accepted_at": r.accepted_at,
                        "digest": r.digest,
                        "deliveries": r.deliveries,
                    },
                );
            }
        }
        response(404, { "error": "not_found" })
    }
    function deliver_once(self) -> void {
        let work = self.store.rpc("lease", {});
        if (work == null) {
            return;
        }
        let run = baml.json.to<StoredRun>(field(work, "run"));
        let destination = str(work, "destination");
        let lease = str(work, "lease");
        let result = {
            self.github.check_current(run.authorized);
            if (destination == "github") {
                let browser = self.browser;
                if (browser != null && run.envelope?.report != null) {
                    let files = baml.json.to<json[]>(workspace_snapshot(browser, null, run, self.github));
                    // Bounded warming before the review link is published; failure is non-fatal.
                    for (let file in files.slice(0, 2)) {
                        workspace_file(self.github, run, file) catch_all (_) { _ => null };
                    }
                }
                sync_bot_review(self.github, run, self.origin,
                    baml.json.to<ReviewDecision[]>(self.store.rpc("review_decisions", {"id": run.id})));
                baml.json.from(
                    self.github.upsert_pr_comment(
                        run,
                        self.origin,
                        events = baml.json.to<json[]>(self.store.rpc("workspace_public", { "id": run.id })),
                        decisions = baml.json.to<ReviewDecision[]>(
                            self.store.rpc("review_decisions", { "id": run.id }),
                        ),
                    ),
                )
            } else {
                baml.json.from(self.slack.publish_review_request(run, self.origin))
            }
        } catch_all (error) {
            _ => {
                let _ = self.store.rpc(
                    "delivery_failed",
                    {
                        "id": run.id,
                        "destination": destination,
                        "lease": lease,
                        "error": "provider_delivery_failed",
                    },
                );
                return;
            },
        };
        let _ = self.store.rpc(
            "delivery_done",
            { "id": run.id, "destination": destination, "lease": lease, "reference": result },
        );
    }
}

function bearer(req: baml.http.ServerRequest) -> string {
    let header = req.headers.get("authorization") ?? "";
    require(header.starts_with("Bearer ") && header.length() < 20000, 401, "bearer_required");
    header.slice(7, header.length())
}

function response(status: int, value: json) -> baml.http.Response {
    baml.http.Response.new(
        status,
        {
            "content-type": "application/json",
            "cache-control": "no-store",
            "x-content-type-options": "nosniff",
        },
        baml.json.stringify(value).to_utf8(),
    )
}

function config(name: string) -> string {
    baml.env.get(name) ?? throw "Missing service configuration"
}

function service() -> ReportService {
    let origin = config("CODETURTLE_API_URL");
    let db = config("CODETURTLE_SUPABASE_URL");
    require(
        matches(origin, "^https://[A-Za-z0-9.-]+(:[0-9]+)?$")
            && matches(db, "^https://[A-Za-z0-9.-]+$"),
        503,
        "invalid_service_origin",
    );
    let http = HttpTransport {};
    let crypto = CryptoHelper {
        python: baml.env.get("CODETURTLE_PYTHON") ?? "python3",
        path: config("CODETURTLE_CRYPTO_PATH"),
    };
    let store = SupabaseStore { url: db, key: config("CODETURTLE_SUPABASE_KEY") };
    let github = GitHubClient {
        http: http,
        crypto: crypto,
        app_id: config("CODETURTLE_GITHUB_APP_ID"),
        private_key: config("CODETURTLE_GITHUB_PRIVATE_KEY"),
        bot_id: baml.Int.parse(config("CODETURTLE_GITHUB_BOT_ID")),
        tokens: bounded_cache(262144),
        contents: bounded_cache(16777216),
    };
    let secrets = SecretBox { key: uint8array.from_hex(config("CODETURTLE_ENCRYPTION_KEY")) };
    let browser = BrowserAuth {
        store: store,
        http: http,
        origin: origin,
        client_id: config("CODETURTLE_WORKOS_CLIENT_ID"),
        client_secret: config("CODETURTLE_WORKOS_API_KEY"),
        organization_id: baml.env.get("CODETURTLE_WORKOS_ORGANIZATION_ID"),
        secrets: secrets,
    };
    ReportService {
        store: store,
        github: github,
        oidc: GitHubOIDC { crypto: crypto, http: http, audience: origin },
        parser: report_parser(config("CODETURTLE_MODELS_PATH")),
        origin: origin,
        slack: SlackClient { http: http, secrets: secrets },
        browser: browser,
        onboarding: Onboarding {
            auth: browser,
            github: github,
            store: store,
            action_ref: baml.env.get("CODETURTLE_ACTION_REF") ?? "",
            runtime_url: baml.env.get("CODETURTLE_RUNTIME_URL") ?? "",
            runtime_sha256: baml.env.get("CODETURTLE_RUNTIME_SHA256") ?? "",
        },
    }
}

function main(addr: string = "0.0.0.0:8080") -> never {
    let app = service();
    let worker = spawn {
        while (true) {
            app.deliver_once() catch_all (_) {
                _ => log.warn("Delivery deferred")
            };
            baml.sys.sleep(baml.time.Duration.from_seconds(2));
        }
    };
    baml.http.Server.bind(addr).serve(
        (req) -> {
            app.handle(req, $trace = service_trace("request"))
        },
        max_body_size = 4194304,
        max_connections = 16,
        header_read_timeout = baml.time.Duration.from_seconds(10),
    )
}
