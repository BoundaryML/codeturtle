class GitHubClient {
    http: Transport,
    crypto: CryptoHelper,
    app_id: string,
    private_key: string,
    bot_id: int,
    function installation_token(self, e: Enrollment, write: bool = false) -> string {
        require(e.active, 403, "installation_inactive");
        let jwt = self.crypto.sign(self.app_id, self.private_key);
        let permissions: json = {
            "contents": "read",
            "actions": "read",
            "pull_requests": if (write) {
                "write"
            } else {
                "read"
            },
        };
        str(
            self.http.send(
                "POST",
                `https://api.github.com/app/installations/${e.installation_id}/access_tokens`,
                jwt,
                { "repository_ids": [baml.Int.parse(e.repository_id)], "permissions": permissions },
            ),
            "token",
        )
    }
    function api(
        self,
        method: string,
        repository: string,
        path: string,
        token: string,
        body: json = null,
    ) -> json {
        self.http.send(method, "https://api.github.com/repos/" + repository + path, token, body)
    }
    function authorize(self, i: RunIdentity, claims: json, e: Enrollment) -> AuthorizedRun {
        require(
            e.repository_id == i.repository_id && e.repository == i.repository && e.active,
            403,
            "repository_not_enrolled",
        );
        require(
            str(claims, "workflow_ref") == e.workflow_ref && str(claims, "workflow_sha") == i.base,
            403,
            "untrusted_workflow",
        );
        let token = self.installation_token(e);
        let repo = self.api("GET", i.repository, "", token);
        require(num(repo, "id").to_string() == i.repository_id, 403, "repository_mismatch");
        let workflow_path = e.workflow_ref.split("@")[0].replace_all(i.repository + "/", "");
        let contents = self.api("GET", i.repository, "/contents/" + workflow_path + "?ref=" + i.base, token);
        require(str(contents, "sha") == e.workflow_blob, 403, "workflow_not_trusted");
        let run = self.api("GET", i.repository, `/actions/runs/${i.run_id}/attempts/${i.run_attempt}`, token);
        require(
            num(run, "id").to_string() == i.run_id
                && num(run, "run_attempt") == i.run_attempt
                && str(run, "event") == "pull_request_target"
                && str(run, "head_sha") == i.base
                && str(run, "path") == workflow_path
                && str(run, "status") == "in_progress",
            403,
            "run_mismatch",
        );
        require(
            baml.json.to<json[]>(field(run, "pull_requests")).some((p) -> {
                num(p, "number") == i.pr
                    && num(field(field(p, "base"), "repo"), "id").to_string() == i.repository_id
            }),
            403,
            "missing_pr_association",
        );
        let pr = self.current_pr(i, token);
        require(str(claims, "ref") == "refs/heads/" + str(field(pr, "base"), "ref"), 403, "ref_mismatch");
        let comparison = self.api("GET", i.repository, `/compare/${i.base}...${i.head}`, token);
        AuthorizedRun {
            identity: i,
            enrollment: e,
            merge_base: str(field(comparison, "merge_base_commit"), "sha"),
            title: str(pr, "title"),
        }
    }
    function current_pr(self, i: RunIdentity, token: string) -> json {
        let pr = self.api("GET", i.repository, `/pulls/${i.pr}`, token);
        require(
            str(pr, "state") == "open"
                && str(field(pr, "head"), "sha") == i.head
                && str(field(pr, "base"), "sha") == i.base
                && num(field(field(pr, "base"), "repo"), "id").to_string() == i.repository_id,
            409,
            "stale_pull_request",
        );
        pr
    }
    function check_current(self, run: AuthorizedRun) -> void {
        let _ = self.current_pr(run.identity, self.installation_token(run.enrollment));
    }
    function upsert_pr_comment(
        self,
        run: StoredRun,
        origin: string,
        decisions: ReviewDecision[] = [],
    ) -> CommentRef {
        let i = run.authorized.identity;
        let token = self.installation_token(run.authorized.enrollment, write = true);
        let _ = self.current_pr(i, token);
        let marker = `<!-- codeturtle:${i.repository_id}:${i.pr} -->`;
        let body = github_report(run, origin, decisions = decisions) + "\n" + marker;
        // Reconcile before creation, including after a lost provider response.
        let page = 1;
        while (page <= 100) {
            let comments = baml.json.to<json[]>(
                self.api(
                    "GET",
                    i.repository,
                    `/issues/${i.pr}/comments?per_page=100&page=${page}`,
                    token,
                ),
            );
            for (let c in comments) {
                if (num(field(c, "user"), "id") == self.bot_id && str(c, "body").includes(marker)) {
                    let updated = self.api(
                        "PATCH",
                        i.repository,
                        `/issues/comments/${num(c, "id")}`,
                        token,
                        body = { "body": body },
                    );
                    return CommentRef { id: num(updated, "id") };
                }
            }
            if (comments.length() < 100) {
                let created = self.api(
                    "POST",
                    i.repository,
                    `/issues/${i.pr}/comments`,
                    token,
                    body = { "body": body },
                );
                return CommentRef { id: num(created, "id") };
            }
            page += 1;
        }
        throw ApiError {status: 503, code: "comment_reconciliation_limit"}
    }
}

function safe_markdown(s: string) -> string {
    s.replace_all("&", "&amp;")
        .replace_all("<", "&lt;")
        .replace_all(">", "&gt;")
        .replace_all("@", "＠")
        .replace_all("`", "\\`")
        .replace_all("|", "&#124;")
        .replace_all("[", "&#91;")
        .replace_all("]", "&#93;")
        .replace_all("\r", " ")
        .replace_all("\n", " ")
}

function github_report(run: StoredRun, origin: string, decisions: ReviewDecision[] = []) -> string {
    let e = run.envelope ?? throw "No report";
    let i = run.authorized.identity;
    let text = `## CodeTurtle review\n\n[View report](${origin}/?run=${run.id}) · Head \`${i.head}\` · Policy \`${i.policy}\`\n\n`;
    if (e.setup_failure != null) {
        return text
            + "Evaluation setup failed. See the CI run for details. Human approval has not been determined.";
    }
    let complete = baml.json.to<bool>(field(e.report, "evaluation_complete"));
    text
        += if (complete) {
            "Evaluation complete. Reviewer sign-offs are tracked below.\n\n"
        } else {
            "Evaluation incomplete; errors or ownership gaps require attention.\n\n"
        };
    let requirements = review_requirements(e.report);
    let reviewed = 0;
    let index = 0;
    for (let r in requirements) {
        if (requirement_reviewed(r, index, decisions)) {
            reviewed += 1;
        }
        index += 1;
    }
    text
        += reviewed.to_string()
            + "/"
            + requirements.length().to_string()
            + " review requirements satisfied (respecting Any/All rules).\n\n";
    text += "| Reviewer | Parts | Progress | Review |\n| --- | --- | --- | --- |\n";
    for (let row in reviewer_rows(e.report, decisions, origin, run.id)) {
        let line = "| "
            + safe_markdown(row.owner)
            + " | "
            + row.parts
                .map((p) -> {
                    safe_markdown(p)
                })
                .join(", ")
            + " | "
            + row.completed.to_string()
            + "/"
            + row.indices.length().to_string()
            + " reviewed | [Open assigned review]("
            + row.url
            + ") |\n";
        if (text.length() + line.length() > 50000) {
            text += "\nAdditional assignments in the report.\n";
            break;
        }
        text += line;
    }
    text += "\nSign-offs apply only to this report and commit. New pushes require a fresh review.\n";
    text
}

test "GitHub content cannot inject mentions or HTML" {
    assert.equal(safe_markdown("@team <script>"), "＠team &lt;script&gt;")
}

function hmac_sha256(key_text: string, text: string) -> string {
    let key = key_text.to_utf8();
    if (key.length() > 64) {
        key = uint8array.from_hex(sha256(key_text));
    }
    let inner = uint8array.zeroes(0);
    let outer = uint8array.zeroes(0);
    let n = 0;
    while (n < 64) {
        let byte = key.at(n) ?? 0;
        inner.push(byte ^ 54);
        outer.push(byte ^ 92);
        n += 1;
    }
    let hash = baml.crypto.Sha256.new();
    hash.update(inner);
    hash.update(text.to_utf8());
    let final_hash = baml.crypto.Sha256.new();
    final_hash.update(outer);
    final_hash.update(hash.finish());
    final_hash.finish().to_hex()
}

function receive_webhook(
    req: baml.http.ServerRequest,
    store: RunStore,
    secret: string,
) -> baml.http.Response {
    let actual = req.headers.get("x-hub-signature-256") ?? "";
    let expected = "sha256=" + hmac_sha256(secret, req.body);
    let diff = actual.length() ^ expected.length();
    let n = 0;
    while (n < expected.length()) {
        diff = diff | ((actual.code_point_at(n) ?? 0) ^ (expected.code_point_at(n) ?? 0));
        n += 1;
    }
    require(diff == 0, 401, "invalid_webhook_signature");
    let delivery = req.headers.get("x-github-delivery") ?? "";
    require(matches(delivery, "^[a-fA-F0-9-]{36}$"), 400, "invalid_webhook_delivery");
    let result = store.rpc(
        "webhook",
        {
            "delivery": delivery,
            "event": req.headers.get("x-github-event") ?? "",
            "payload": baml.json.parse(req.body),
        },
    );
    response(200, result)
}

test "GitHub webhook HMAC standard vector" {
    assert.equal(
        hmac_sha256("key", "The quick brown fox jumps over the lazy dog"),
        "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
    )
}
