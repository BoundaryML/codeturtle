// Production adapter for the original tools/shep review workspace.
function workspace_snapshot(
    auth: BrowserAuth,
    actor: json,
    run: StoredRun,
    github: GitHubClient,
) -> json {
    let cached = auth.store.rpc("workspace_snapshot", { "actor": actor, "id": run.id });
    if (cached != null) {
        return cached;
    }
    let token = github.installation_token(run.authorized.enrollment);
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
    let changes = baml.json.to<json[]>(field(comparison, "files"));
    let requirements = review_requirements(run.envelope?.report);
    let paths = changes.map((f) -> {
        str(f, "filename")
    });
    for (let r in requirements) {
        if (!paths.includes(str(r, "path"))) {
            paths.push(str(r, "path"));
        }
    }
    let files: json[] = [];
    for (let path in paths) {
        let change = changes.find((f) -> {
            str(f, "filename") == path
        });
        let rules = requirements.filter((r) -> {
            str(r, "path") == path
        });
        let owners: string[] = [];
        for (let r in rules) {
            for (let o in baml.json.to<string[]>(field(r, "owners"))) {
                let user = o.to_lower_case().slice(1, o.length());
                if (!owners.includes(user)) {
                    owners.push(user);
                }
            }
        }
        let fingerprint = if (change == null) {
            run.authorized.identity.head
        } else {
            baml.json.stringify(field(change, "sha"))
                + baml.json.stringify(field(change, "patch"))
                + baml.json.stringify(field(change, "status"))
        };
        files.push(
            {
                "id": path,
                "owners": baml.json.from(owners),
                "requirements": baml.json.from(rules),
                "revision": sha256(
                    path
                        + fingerprint
                        + baml.json.stringify(
                            baml.json.from(
                                rules.map((r) -> {
                                    {
                                        "owners": field(r, "owners"),
                                        "approval": field(r, "approval"),
                                    }
                                }),
                            ),
                        ),
                ),
                "change": change,
            },
        );
    }
    auth.store.rpc(
        "workspace_snapshot",
        { "actor": actor, "id": run.id, "files": baml.json.from(files) },
    )
}

function workspace_get(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    github: GitHubClient,
) -> json {
    let actor = field(auth.session(req), "actor");
    let id = query(req.url).get("run") ?? "";
    require(matches(id, "^[a-f0-9-]{36}$"), 400, "invalid_run");
    let run = baml.json.to<StoredRun>(auth.store.rpc("review_run", { "actor": actor, "id": id }));
    let reviewer = reviewer_identity(auth, req, run);
    let files = workspace_snapshot(auth, actor, run, github);
    let current = {
        github.check_current(run.authorized);
        true
    } catch_all (_) {
        _ => false
    };
    let admin = {
        let membership = auth.store.rpc(
            "authorize",
            {
                "actor": actor,
                "repository_id": run.authorized.identity.repository_id,
                "setup": true,
            },
        );
        let who = baml.json.to<Actor>(actor);
        let token = auth.secrets.open(
            str(membership, "encrypted_token"),
            "github-user:" + who.user_id + ":" + run.authorized.identity.repository_id,
        );
        let repo = auth.http.send(
            "GET",
            "https://api.github.com/repos/" + run.authorized.identity.repository,
            token,
            null,
        );
        field(field(repo, "permissions"), "admin") == true
    } catch_all (_) {
        _ => false
    };
    {
        "review": auth.store.rpc("review", { "actor": actor, "id": id }),
        "reviewer": baml.json.from(reviewer),
        "files": files,
        "state": auth.store.rpc("workspace", { "actor": actor, "id": id }),
        "current": current,
        "admin": admin,
    }
}

function workspace_write(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    github: GitHubClient,
) -> json {
    let actor = field(auth.session(req, mutation = true), "actor");
    let body = baml.json.parse(req.body);
    let id = str(body, "run_id");
    require(matches(id, "^[a-f0-9-]{36}$"), 400, "invalid_run");
    let run = baml.json.to<StoredRun>(auth.store.rpc("review_run", { "actor": actor, "id": id }));
    let reviewer = reviewer_identity(auth, req, run);
    if (field(body, "action") == "override") {
        let _ = auth.authorize(req, run.authorized.identity.repository_id, setup = true);
    }
    github.check_current(run.authorized);
    auth.store.rpc(
        "workspace_write",
        {
            "actor": actor,
            "id": id,
            "head": field(body, "head"),
            "github_user_id": reviewer.user_id,
            "github_login": reviewer.login,
            "eligible_owners": baml.json.from(reviewer.eligible_owners),
            "action": field(body, "action"),
            "draft": field(body, "draft"),
            "block": field(body, "block"),
            "reason": field(body, "reason"),
        },
    )
}

function workspace_content(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    github: GitHubClient,
) -> json {
    let q = query(req.url);
    let id = q.get("run") ?? "";
    require(matches(id, "^[a-f0-9-]{36}$"), 400, "invalid_run");
    let actor = field(auth.session(req), "actor");
    let run = baml.json.to<StoredRun>(auth.store.rpc("review_run", { "actor": actor, "id": id }));
    let _ = auth.authorize(req, run.authorized.identity.repository_id);
    let files = baml.json.to<json[]>(workspace_snapshot(auth, actor, run, github));
    let file = files.find((f) -> {
        str(f, "id") == (q.get("file") ?? "")
    });
    require(file != null, 404, "file_not_found");
    let change = field(file, "change");
    require(change != null, 422, "github_diff_limit_open_on_github");
    let path = str(file, "id");
    let old_path = baml.json.to<string?>(field(change, "previous_filename")) ?? path;
    let token = github.installation_token(run.authorized.enrollment);
    let original = if (field(change, "status") == "added") {
        ""
    } else {
        workspace_text(github, run.authorized.identity.repository, old_path, run.authorized.merge_base, token)
    };
    let modified = if (field(change, "status") == "removed") {
        ""
    } else {
        workspace_text(github, run.authorized.identity.repository, path, run.authorized.identity.head, token)
    };
    { "original": original, "modified": modified }
}

function workspace_text(
    github: GitHubClient,
    repository: string,
    path: string,
    revision: string,
    token: string,
) -> string {
    let data = github.api(
        "GET",
        repository,
        "/contents/"
            + path.split("/")
                .map((s) -> {
                    url_encode(s)
                })
                .join("/")
            + "?ref="
            + revision,
        token,
    );
    require(
        field(data, "encoding") == "base64" && num(data, "size") <= 1000000,
        422,
        "large_or_binary_file_open_on_github",
    );
    let content = uint8array.from_base64(str(data, "content").replace_all("\n", "")).to_string();
    require(!content.includes("\u0000"), 422, "binary_file_open_on_github");
    content
}
