// GitHub API access (server side) and the publisher. The publisher
// applies desired backend state to the check run, bot review, and one
// summary comment. It uses CODETURTLE_GITHUB_TOKEN (an App installation
// token minted externally; App JWT signing needs RS256, which the
// BAML stdlib does not expose yet). Without a token, publication stays
// visibly pending instead of claiming success.

function srv_github_token() -> string? {
    root.lib.env.env_or_null("CODETURTLE_GITHUB_TOKEN")
}

class GhResult {
    status: int,
    body: string,
}

function srv_github(method: string, path: string, token: string?, body: string) -> GhResult {
    let headers: map<string, string> = {
        "accept": "application/vnd.github+json",
        "content-type": "application/json",
        "user-agent": "codeturtle-backend",
        "x-github-api-version": "2022-11-28",
    };
    if (token != null) {
        headers["authorization"] = `Bearer ${token ?? ""}`;
    }
    let response = baml.http.send(
        baml.http.Request {
            method: method,
            url: `https://api.github.com${path}`,
            headers: headers,
            body: body,
            timeout: baml.time.Duration.from_seconds(root.lib.limits.Limits.http_timeout_seconds()),
            connect_timeout: baml.time.Duration.from_seconds(root.lib.limits.Limits.http_timeout_seconds()),
        },
    ) catch (e) {
        baml.errors.Io => null,
        baml.errors.Timeout => null,
        baml.errors.InvalidArgument => null,
    };
    match (response) {
        null => GhResult { status: 0, body: "" },
        let r: baml.http.Response => {
            let text = r.text() catch (e) {
                baml.errors.Io => "",
                baml.errors.Timeout => "",
            };
            GhResult { status: r.status_code, body: text }
        },
    }
}

function srv_json_string(body: string, path: string) -> string? {
    let parsed = baml.json.parse(body) catch (e) {
        baml.json.ParseError => null,
    };
    match (parsed) {
        null => null,
        let j: baml.json.json => {
            let found = baml.json.path_or(j, `.${path}`, "");
            match (found) {
                "" => null,
                let s: string => s,
            }
        },
    }
}

function srv_json_id(body: string, path: string) -> string? {
    let parsed = baml.json.parse(body) catch (e) {
        baml.json.ParseError => null,
    };
    match (parsed) {
        null => null,
        let j: baml.json.json => {
            let n = baml.json.path_or(j, `.${path}`, 0);
            if (n == 0) {
                srv_json_string(body, path)
            } else {
                string.from(n)
            }
        },
    }
}

class GhPrHeads {
    head_sha: string,
    base_sha: string,
    title: string,
    author_login: string,
}

function srv_fetch_pr_heads(repository: string, number: int) -> GhPrHeads? {
    let result = srv_github("GET", `/repos/${repository}/pulls/${number}`, srv_github_token(), "");
    if (result.status < 200 || result.status >= 300) {
        return null;
    }
    let head = srv_json_string(result.body, "head.sha");
    let base = srv_json_string(result.body, "base.sha");
    if (head == null || base == null) {
        return null;
    }
    GhPrHeads {
        head_sha: head ?? "",
        base_sha: base ?? "",
        title: srv_json_string(result.body, "title") ?? "",
        author_login: srv_json_string(result.body, "user.login") ?? "",
    }
}

function srv_fetch_merge_base(repository: string, base: string, head: string) -> string? {
    let result = srv_github("GET", `/repos/${repository}/compare/${base}...${head}`, srv_github_token(), "");
    if (result.status < 200 || result.status >= 300) {
        return null;
    }
    srv_json_string(result.body, "merge_base_commit.sha")
}

function srv_team_memberships(
    evaluation: EvaluationRecord,
    actor_login: string,
    actor_token: string,
) -> map<string, bool> {
    let memberships: map<string, bool> = {};
    let teams: string[] = [];
    for (let r in evaluation.requirements) {
        for (let owner in r.owners) {
            let body = if (owner.starts_with("@")) {
                owner.slice(1, owner.length())
            } else {
                owner
            };
            if (body.includes("/") && !teams.includes(body)) {
                teams.push(body);
            }
        }
    }
    for (let team in teams) {
        let parts = team.split("/");
        let result = srv_github("GET", `/orgs/${parts[0]}/teams/${parts[1]}/memberships/${actor_login}`, actor_token, "");
        let state = srv_json_string(result.body, "state") ?? "";
        memberships[`${team}|${actor_login.to_lower_case()}`]
            = result.status == 200 && state == "active";
    }
    memberships
}

function srv_summary_text(store: StoreState, pr: PrRecord) -> string {
    let evaluation = srv_current_evaluation(store, pr);
    let lines: string[] = [
        "<!-- codeturtle -->",
        "## CodeTurtle review",
        "",
        `State: **${pr.state}** (publication: ${pr.publication})`,
    ];
    match (evaluation) {
        null => lines.push("Waiting for evaluation."),
        let e: EvaluationRecord => {
            lines.push(`Head: ${root.lib.text.Text.short_rev(e.inputs.head)}`);
            let latest = srv_latest_decisions(store, e.id);
            for (let r in e.requirements) {
                let done = srv_requirement_satisfied(r, latest, {}, pr.author_login, srv_allow_self_review(store, pr));
                let box = if (done) {
                    "x"
                } else {
                    " "
                };
                lines.push(
                    `- [${box}] ${r.path} - ${r.threshold_label()} ${r.owners.join(", ")} - ${r.reason}`,
                );
            }
            for (let objection in srv_open_objections(store, pr.id, null)) {
                lines.push(
                    `- Open objection by @${objection.actor_login} on ${objection.path}: ${objection.explanation}`,
                );
            }
            null
        },
    };
    lines.join("\n")
}

class CheckRunPayload {
    name: string,
    head_sha: string,
    status: string,
    conclusion: string?,
}

class ReviewPayload {
    commit_id: string,
    event: string,
}

class CommentPayload {
    body: string,
}

function srv_publish(store: StoreState, pr: PrRecord) -> null {
    let token = srv_github_token();
    if (token == null) {
        pr.publication = "pending";
        return null;
    }
    let evaluation = srv_current_evaluation(store, pr);
    let head = match (evaluation) {
        null => null,
        let e: EvaluationRecord => e.inputs.head,
    };
    if (head == null) {
        pr.publication = "pending";
        return null;
    }
    let result = srv_publish_inner(store, pr, token ?? "", head ?? "");
    pr.publication
        = if (result) {
            "synced"
        } else {
            "error"
        };
    srv_save(store, srv_db_path());
    null
}

function srv_publish_inner(store: StoreState, pr: PrRecord, token: string, head: string) -> bool {
    let summary = srv_summary_text(store, pr);
    let status = match (pr.state) {
        "approved" => ["completed", "success"],
        "blocked" => ["completed", "failure"],
        "evaluation_error" => ["completed", "failure"],
        _ => ["in_progress", ""],
    };
    if (pr.state == "approved") {
        let heads = srv_fetch_pr_heads(pr.repository, pr.number);
        match (heads) {
            null => false,
            let current: GhPrHeads => {
                if (current.head_sha != head) {
                    pr.state = "evaluating";
                    return srv_publish_check(pr, token, head, "in_progress", "", summary);
                }
                let review_body = baml.json.to_string(ReviewPayload { commit_id: head, event: "APPROVE" }) catch (e) {
                    baml.json.SerializationError => "",
                };
                let review = srv_github("POST", `/repos/${pr.repository}/pulls/${pr.number}/reviews`, token, review_body);
                if (review.status >= 200 && review.status < 300) {
                    pr.bot_review_id = srv_json_id(review.body, "id");
                    srv_publish_check(pr, token, head, status[0], status[1], summary)
                        && srv_publish_comment(pr, token, summary)
                } else {
                    false
                }
            },
        }
    } else {
        srv_dismiss_bot_review(pr, token);
        srv_publish_check(pr, token, head, status[0], status[1], summary)
            && srv_publish_comment(pr, token, summary)
    }
}

function srv_dismiss_bot_review(pr: PrRecord, token: string) -> null {
    match (pr.bot_review_id) {
        null => null,
        let review_id: string => {
            srv_github(
                "PUT",
                `/repos/${pr.repository}/pulls/${pr.number}/reviews/${review_id}/dismissals`,
                token,
                "{\"message\":\"CodeTurtle requirements changed\"}",
            );
            pr.bot_review_id = null;
            null
        },
    }
}

function srv_publish_check(
    pr: PrRecord,
    token: string,
    head: string,
    status: string,
    conclusion: string,
    summary: string,
) -> bool {
    let payload = baml.json.to_string(
        CheckRunPayload {
            name: "CodeTurtle review",
            head_sha: head,
            status: status,
            conclusion: if (conclusion.is_empty()) {
                null
            } else {
                conclusion
            },
        },
    ) catch (e) {
        baml.json.SerializationError => "",
    };
    let result = match (pr.check_run_id) {
        null => srv_github("POST", `/repos/${pr.repository}/check-runs`, token, payload),
        let id: string => {
            srv_github("PATCH", `/repos/${pr.repository}/check-runs/${id}`, token, payload)
        },
    };
    if (result.status >= 200 && result.status < 300) {
        let check_id = srv_json_id(result.body, "id");
        if (check_id != null) {
            pr.check_run_id = check_id;
        }
        true
    } else {
        false
    }
}

function srv_publish_comment(pr: PrRecord, token: string, summary: string) -> bool {
    let payload = baml.json.to_string(CommentPayload { body: summary }) catch (e) {
        baml.json.SerializationError => "",
    };
    let result = match (pr.summary_comment_id) {
        null => {
            srv_github("POST", `/repos/${pr.repository}/issues/${pr.number}/comments`, token, payload)
        },
        let id: string => {
            srv_github("PATCH", `/repos/${pr.repository}/issues/comments/${id}`, token, payload)
        },
    };
    if (result.status >= 200 && result.status < 300) {
        let comment_id = srv_json_id(result.body, "id");
        if (comment_id != null) {
            pr.summary_comment_id = comment_id;
        }
        true
    } else {
        false
    }
}
