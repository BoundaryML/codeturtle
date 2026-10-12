class ReviewDecision {
    requirement_index: int,
    owner: string,
    github_user_id: string,
    github_login: string,
    reviewed_at: string,
}

class ReviewerRow {
    owner: string,
    parts: string[],
    indices: int[],
    completed: int,
    url: string,
}

class ReviewIdentity {
    user_id: string,
    login: string,
    eligible_owners: string[],
}

function review_requirements(report: json) -> json[] {
    if (report == null) {
        []
    } else {
        baml.json.to<json[]>(field(report, "requirements"))
    }
}

function reviewer_rows(
    report: json,
    decisions: ReviewDecision[],
    origin: string,
    run_id: string,
) -> ReviewerRow[] {
    let rows: ReviewerRow[] = [];
    let index = 0;
    for (let requirement in review_requirements(report)) {
        for (let raw in baml.json.to<string[]>(field(requirement, "owners"))) {
            let owner = raw.to_lower_case();
            let existing = rows.find((r) -> {
                r.owner == owner
            });
            let row = existing
                ?? ReviewerRow {
                    owner: owner,
                    parts: [],
                    indices: [],
                    completed: 0,
                    url: origin + "/?run=" + run_id + "&reviewer=" + url_encode(owner),
                };
            if (!row.indices.includes(index)) {
                row.indices.push(index);
                if (!row.parts.includes(str(requirement, "path"))) {
                    row.parts.push(str(requirement, "path"));
                }
                if (
                    decisions.some((d) -> {
                        d.requirement_index == index && d.owner == owner
                    })
                ) {
                    row.completed += 1;
                }
            }
            if (existing == null) {
                rows.push(row);
            }
        }
        index += 1;
    }
    rows
}

function requirement_reviewed(requirement: json, index: int, decisions: ReviewDecision[]) -> bool {
    let owners = baml.json.to<string[]>(field(requirement, "owners"));
    let done = (owner: string) -> {
        decisions.some((d) -> {
            d.requirement_index == index && d.owner == owner.to_lower_case()
        })
    };
    if (str(requirement, "approval") == "All") {
        owners.length() > 0 && owners.every(done)
    } else {
        owners.some(done)
    }
}

function reviewer_identity(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    run: StoredRun,
    actor: Actor,
) -> ReviewIdentity {
    let repository_id = run.authorized.identity.repository_id;
    let token = auth.repository_access(actor, repository_id);
    reviewer_with_token(auth, run, token)
}

function reviewer_with_token(auth: BrowserAuth, run: StoredRun, token: string) -> ReviewIdentity {
    let user = github_user_get(auth.http, "https://api.github.com/user", token);
    let login = str(user, "login").to_lower_case();
    let eligible = ["@" + login];
    let e = run.envelope;
    if (e != null) {
        for (let row in reviewer_rows(e.report, [], auth.origin, run.id)) {
            if (row.owner.includes("/") && matches(row.owner, "^@[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$")) {
                let parts = row.owner.slice(1, row.owner.length()).split("/");
                let active = {
                    let member = auth.http.send(
                        "GET",
                        "https://api.github.com/orgs/"
                            + parts[0]
                            + "/teams/"
                            + parts[1]
                            + "/memberships/"
                            + login,
                        token,
                        null,
                    );
                    field(member, "state") == "active"
                } catch_all (_) {
                    _ => false
                };
                if (active) {
                    eligible.push(row.owner);
                }
            }
        }
    }
    ReviewIdentity { user_id: num(user, "id").to_string(), login: login, eligible_owners: eligible }
}

function review_page(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    github: GitHubClient,
) -> json {
    let actor = field(auth.session(req), "actor");
    let id = query(req.url).get("run") ?? "";
    require(matches(id, "^[a-f0-9-]{36}$"), 400, "invalid_run");
    let view = auth.store.rpc("review", { "actor": actor, "id": id });
    let run = baml.json.to<StoredRun>(auth.store.rpc("review_run", { "actor": actor, "id": id }));
    let reviewer = reviewer_identity(auth, req, run, baml.json.to<Actor>(actor));
    let decisions = baml.json.to<ReviewDecision[]>(auth.store.rpc("review_decisions", { "id": id }));
    let current = {
        github.check_current(run.authorized);
        true
    } catch_all (_) {
        _ => false
    };
    let report = run.envelope?.report;
    let requirements = review_requirements(report);
    let completed = 0;
    let index = 0;
    for (let r in requirements) {
        if (requirement_reviewed(r, index, decisions)) {
            completed += 1;
        }
        index += 1;
    }
    {
        "review": view,
        "reviewer": baml.json.from(reviewer),
        "decisions": baml.json.from(decisions),
        "reviewers": baml.json.from(reviewer_rows(report, decisions, auth.origin, id)),
        "current": current,
        "completed_requirements": completed,
        "total_requirements": requirements.length(),
    }
}

test "Reviewer rows group parts and retain independent All requirements" {
    let report: json = {
        "requirements": [
            { "path": "a.ts", "owners": ["@Alice", "@bob"], "approval": "All" },
            { "path": "b.ts", "owners": ["@alice"], "approval": "Any" },
        ],
    };
    let decisions = [
        ReviewDecision {
            requirement_index: 0,
            owner: "@alice",
            github_user_id: "1",
            github_login: "alice",
            reviewed_at: "now",
        },
    ];
    let rows = reviewer_rows(report, decisions, "https://example.test", "run");
    assert.equal(rows.length(), 2);
    assert.equal(rows[0].parts, ["a.ts", "b.ts"]);
    assert.equal(rows[0].completed, 1);
    assert.equal(requirement_reviewed(review_requirements(report)[0], 0, decisions), false);
    assert.contains(rows[0].url, "reviewer=%40alice")
}

function review_diff(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    github: GitHubClient,
) -> json {
    let q = query(req.url);
    let id = q.get("run") ?? "";
    require(matches(id, "^[a-f0-9-]{36}$"), 400, "invalid_run");
    let run = baml.json.to<StoredRun>(
        auth.store.rpc("review_run", { "actor": field(auth.session(req), "actor"), "id": id }),
    );
    let _ = auth.authorize(req, run.authorized.identity.repository_id);
    let index = baml.Int.parse(q.get("index") ?? "-1");
    let requirements = review_requirements(run.envelope?.report);
    require(index >= 0 && index < requirements.length(), 400, "invalid_requirement");
    let path = str(requirements[index], "path");
    let token = github.installation_token(run.authorized.enrollment);
    // Compare immutable commits. GitHub includes at most 300 files in this response.
    let comparison = github.api(
        "GET",
        run.authorized.identity.repository,
        "/compare/"
            + run.authorized.merge_base
            + "..."
            + run.authorized.identity.head
            + "?per_page=1",
        token,
    );
    let files = baml.json.to<json[]>(field(comparison, "files"));
    let file = files.find((f) -> {
        str(f, "filename") == path
    });
    if (file == null) {
        {
            "patch": null,
            "message": "Diff is outside GitHub's response limit. Open the PR files on GitHub.",
        }
    } else {
        {
            "patch": field(file, "patch"),
            "message": "Binary or large files may require viewing on GitHub.",
        }
    }
}
