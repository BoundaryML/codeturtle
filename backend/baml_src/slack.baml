function format_mention(id: string) -> string {
    require(matches(id, "^[UW][A-Z0-9]{2,}$"), 400, "invalid_slack_id");
    "<@" + id + ">"
}

function resolve_mentions(owners: string[], mapping: map<string, string>) -> MentionResult {
    let result = MentionResult { mentions: [], unmapped: [] };
    for (let owner in owners) {
        if let id: string = mapping.get(owner) {
            let mention = format_mention(id);
            if (!result.mentions.includes(mention)) {
                result.mentions.push(mention);
            }
        } else if (!result.unmapped.includes(owner)) {
            result.unmapped.push(owner);
        }
    }
    result
}

function slack_escape(text: string) -> string {
    text.replace_all("&", "&amp;").replace_all("<", "&lt;").replace_all(">", "&gt;")
}

class SlackClient {
    http: Transport,
    secrets: SecretBox,
    function slack_api(self, installation: SlackInstallation, method: string, body: json) -> json {
        let token = self.secrets.open(installation.encrypted_token, "slack:" + installation.workspace_id);
        let result = self.http.send("POST", "https://slack.com/api/" + method, token, body);
        require(field(result, "ok") == true, 502, "slack_api_failed");
        result
    }
    function publish_review_request(self, run: StoredRun, origin: string) -> SlackRef {
        let installation = run.authorized.enrollment.slack ?? throw "Slack is not configured";
        let auth = self.slack_api(installation, "auth.test", {});
        require(str(auth, "team_id") == installation.workspace_id, 403, "workspace_mismatch");
        let marker = "codeturtle:"
            + run.authorized.identity.repository_id
            + ":"
            + run.authorized.identity.pr.to_string();
        let cursor = "";
        let previous: string? = null;
        let page = 0;
        // Exhaust history before creating, or fail visibly without duplicating.
        while (page < 100) {
            let history = self.slack_api(
                installation,
                "conversations.history",
                {
                    "channel": installation.channel,
                    "limit": 100,
                    "cursor": cursor,
                    "include_all_metadata": true,
                },
            );
            for (let m in baml.json.to<json[]>(field(history, "messages"))) {
                if (
                    field(m, "user") == field(auth, "user_id")
                        && field(field(field(m, "metadata"), "event_payload"), "key") == marker
                ) {
                    previous = str(m, "ts");
                    break;
                }
            }
            cursor = baml.json.path_or<string>(history, "response_metadata.next_cursor", "");
            if (previous != null || cursor == "") {
                break;
            }
            page += 1;
        }
        require(previous != null || cursor == "", 503, "slack_reconciliation_limit");
        let e = run.envelope ?? throw "No envelope";
        let owners: string[] = [];
        if (e.report != null) {
            for (let r in baml.json.to<json[]>(field(e.report, "requirements"))) {
                owners = owners.concat(baml.json.to<string[]>(field(r, "owners")));
            }
        }
        let mentions = resolve_mentions(owners, installation.owners);
        let state = if (e.setup_failure != null) {
            "Setup failed"
        } else if (field(e.report, "evaluation_complete") == true) {
            "Evaluation complete"
        } else {
            "Evaluation incomplete"
        };
        let text = `${state}: <${origin}/?run=${run.id}|CodeTurtle report> · <https://github.com/${run.authorized.identity.repository}/pull/${run.authorized.identity.pr}|PR>\nHuman approval has not been determined.`;
        if (previous == null) {
            text += "\n" + mentions.mentions.join(" ");
        }
        if (mentions.unmapped.length() > 0) {
            text
                += "\nUnmapped owners: "
                    + mentions.unmapped
                        .map((o) -> {
                            slack_escape(o)
                        })
                        .join(", ");
        }
        let body: map<string, json> = {
            "channel": installation.channel,
            "text": text,
            "unfurl_links": false,
            "unfurl_media": false,
            "parse": "none",
            "metadata": { "event_type": "codeturtle_report", "event_payload": { "key": marker } },
        };
        if (previous != null) {
            body["ts"] = previous;
        }
        let response = self.slack_api(
            installation,
            if (previous == null) {
                "chat.postMessage"
            } else {
                "chat.update"
            },
            body,
        );
        SlackRef {
            workspace_id: installation.workspace_id,
            channel: installation.channel,
            ts: str(response, "ts"),
        }
    }
}

test "Slack mappings deduplicate and expose missing owners" {
    let r = resolve_mentions(["@one", "@two", "@missing"], { "@one": "U123", "@two": "U123" });
    assert.equal(r.mentions, ["<@U123>"]);
    assert.equal(r.unmapped, ["@missing"]);
    assert.equal(slack_escape("<!channel>"), "&lt;!channel&gt;")
}

test "Slack rejects mention injection" {
    let rejected = format_mention("U123><!channel") catch_all (_) {
        _ => "rejected"
    };
    assert.equal(rejected, "rejected")
}

function start_slack(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    repository_id: string,
    client_id: string,
) -> baml.http.Response {
    let actor = auth.authorize(req, repository_id);
    let state = secret();
    let _ = auth.store.rpc(
        "authorize",
        { "actor": baml.json.from(actor), "repository_id": repository_id, "setup": true },
    );
    let _ = auth.store.rpc(
        "oauth_put",
        {
            "hash": sha256(state),
            "purpose": "slack",
            "data": { "actor": baml.json.from(actor), "repository_id": repository_id },
            "expires_at": now() + 600,
        },
    );
    redirect(
        "https://slack.com/oauth/v2/authorize?client_id="
            + url_encode(client_id)
            + "&scope=chat:write,channels:history,groups:history,users:read&redirect_uri="
            + url_encode(auth.origin + "/auth/slack/callback")
            + "&state="
            + state,
        set_cookie = "__Host-ct_slack=" + state + "; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=600",
    )
}

function complete_install(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    slack: SlackClient,
    client_id: string,
    client_secret: string,
) -> baml.http.Response {
    let q = query(req.url);
    let state = q.get("state") ?? "";
    require(state.length() == 64 && cookie(req, "__Host-ct_slack") == state, 403, "invalid_slack_state");
    let data = auth.store.rpc("oauth_take", { "hash": sha256(state), "purpose": "slack" });
    require(field(auth.session(req), "actor") == field(data, "actor"), 403, "slack_actor_mismatch");
    let repository = str(data, "repository_id");
    let _ = auth.authorize(req, repository);
    let body = "client_id="
        + url_encode(client_id)
        + "&client_secret="
        + url_encode(client_secret)
        + "&code="
        + url_encode(q.get("code") ?? "")
        + "&redirect_uri="
        + url_encode(auth.origin + "/auth/slack/callback");
    let response = baml.http.send(
        baml.http.Request.from_url("https://slack.com/api/oauth.v2.access")
            .set_method("POST")
            .set_headers({ "content-type": "application/x-www-form-urlencoded" })
            .set_body(body)
            .set_timeout(baml.time.Duration.from_seconds(15)),
    );
    require(response.status_code == 200, 502, "slack_oauth_failed");
    let result = baml.json.parse(response.text());
    require(field(result, "ok") == true, 502, "slack_oauth_failed");
    let workspace = str(field(result, "team"), "id");
    let installation = SlackInstallation {
        workspace_id: workspace,
        channel: "",
        encrypted_token: slack.secrets.seal(str(result, "access_token"), "slack:" + workspace),
        owners: {},
    };
    let _ = auth.store.rpc(
        "slack_save",
        {
            "repository_id": repository,
            "actor": field(data, "actor"),
            "installation": baml.json.from(installation),
        },
    );
    redirect("/?repository=" + repository)
}

function link_owner(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    slack: SlackClient,
    repository: string,
    owner: string,
    id: string,
    channel: string,
) -> json {
    let actor = auth.authorize(req, repository, setup = true);
    require(
        matches(owner, "^@[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)?$")
            && matches(channel, "^[CG][A-Z0-9]{2,}$"),
        400,
        "invalid_slack_mapping",
    );
    let _ = format_mention(id);
    let e = auth.store.enrollment(repository);
    let installation = e.slack ?? throw ApiError {status: 409, code: "slack_not_installed"};
    let user = field(slack.slack_api(installation, "users.info", { "user": id }), "user");
    require(
        str(user, "team_id") == installation.workspace_id
            && field(user, "deleted") != true
            && field(user, "is_bot") != true,
        400,
        "invalid_workspace_user",
    );
    let _ = slack.slack_api(installation, "conversations.history", { "channel": channel, "limit": 1 });
    installation.channel = channel;
    installation.owners[owner] = id;
    auth.store.rpc(
        "slack_save",
        {
            "repository_id": repository,
            "actor": baml.json.from(actor),
            "installation": baml.json.from(installation),
        },
    )
}
