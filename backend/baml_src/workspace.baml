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

// Context is server-only and includes encrypted credentials. Never serialize it to the browser.
function workspace_context(auth: BrowserAuth, req: baml.http.ServerRequest, id: string, mutation: bool = false) -> json {
    require(matches(id, "^[a-f0-9-]{36}$"), 400, "invalid_run");
    let token = cookie(req, "__Host-ct_session");
    require(token.length() == 64, 401, "login_required");
    let context = auth.store.rpc("workspace_context", {"token_hash": sha256(token), "id": id});
    if (mutation) {
        require(req.headers.get("origin") == auth.origin && req.headers.get("x-csrf-token") == str(context, "csrf"), 403, "csrf_required");
    }
    context
}

function workspace_access(auth: BrowserAuth, context: json) -> json {
    let e = baml.json.to<Enrollment>(field(context, "enrollment"));
    let token = workspace_token(auth, context);
    let repo = auth.http.send("GET", "https://api.github.com/repos/" + e.repository, token, null);
    require(num(repo, "id").to_string() == e.repository_id && field(field(repo, "permissions"), "pull") == true, 403, "repository_access_revoked");
    {"token": token, "admin": field(context, "can_setup") == true && field(field(repo, "permissions"), "admin") == true}
}

function workspace_get(auth: BrowserAuth, req: baml.http.ServerRequest, github: GitHubClient) -> json {
    let context = workspace_context(auth, req, query(req.url).get("run") ?? "");
    let actor = field(context, "actor");
    let run = workspace_run(context);
    let access_future = spawn { workspace_access(auth, context) };
    let reviewer_future = spawn { reviewer_with_token(auth, run, workspace_token(auth, context)) };
    let state_future = spawn { auth.store.rpc("workspace_view", {"actor":actor, "id":run.id}) };
    let current_future = spawn { { github.check_current(run.authorized); true } catch_all (_) { _ => false } };
    let files = if (field(context, "files") != null) {field(context, "files")} else {workspace_snapshot(auth, actor, run, github)};
    let access = await access_future;
    let reviewer = await reviewer_future;
    let report: json = if (run.envelope == null) {null} else { {"report": {"evaluation_complete":field(run.envelope?.report, "evaluation_complete"), "errors":field(run.envelope?.report, "errors"), "unowned_files":field(run.envelope?.report, "unowned_files")}} };
    {"csrf": field(context,"csrf"), "review": {"run_id":run.id, "identity":baml.json.from(run.authorized.identity), "title":run.authorized.title, "envelope":report, "deliveries":baml.json.from(run.deliveries)}, "reviewer":baml.json.from(reviewer), "files":files, "state":await state_future, "current":await current_future, "admin":field(access,"admin")}
}

function workspace_write(auth: BrowserAuth, req: baml.http.ServerRequest, github: GitHubClient) -> json {
    let body = baml.json.parse(req.body);
    let context = workspace_context(auth, req, str(body,"run_id"), mutation = true);
    let run = workspace_run(context);
    let access_future = spawn { workspace_access(auth, context) };
    let reviewer = reviewer_with_token(auth, run, workspace_token(auth, context));
    let access = await access_future;
    let operation = field(body,"action") == "operation";
    if (field(body,"action") == "override") { require(field(access,"admin") == true,403,"repository_access_revoked"); }
    // Private operations are bound to the immutable run and validated in SQL. Publication
    // and legacy writes still synchronously verify GitHub's live head before committing.
    if (!operation) { github.check_current(run.authorized); }
    if (operation) { require(matches(str(body,"operation_id"), "^[a-f0-9-]{36}$"),400,"invalid_operation"); }
    let result = auth.store.rpc(if (operation) {"draft_operation"} else {if (field(body,"action") == "submit" && field(body,"expected_version") != null) {"workspace_submit"} else {"workspace_write"}}, {
        "actor":field(context,"actor"), "id":run.id, "head":field(body,"head"), "github_user_id":reviewer.user_id, "github_login":reviewer.login, "eligible_owners":baml.json.from(reviewer.eligible_owners), "action":field(body,"action"), "draft":field(body,"draft"), "block":field(body,"block"), "reason":field(body,"reason"), "operation_id":field(body,"operation_id"), "expected_version":field(body,"expected_version"), "operation":field(body,"operation")
    });
    result
}

function workspace_comments(auth: BrowserAuth, req: baml.http.ServerRequest) -> json {
    let q = query(req.url);
    let context = workspace_context(auth, req, q.get("run") ?? "");
    let _ = workspace_access(auth, context);
    let after = q.get("after") ?? "0";
    require(matches(after,"^[0-9]{1,18}$"),400,"invalid_cursor");
    auth.store.rpc("workspace_comments", {"actor":field(context,"actor"),"id":q.get("run") ?? "", "file":q.get("file") ?? "", "after":baml.Int.parse(after)})
}

function workspace_state(auth: BrowserAuth, req: baml.http.ServerRequest) -> json {
    let context = workspace_context(auth, req, query(req.url).get("run") ?? "");
    let _ = workspace_access(auth, context);
    auth.store.rpc("workspace_view", {"actor":field(context,"actor"),"id":query(req.url).get("run") ?? ""})
}

function workspace_content(auth: BrowserAuth, req: baml.http.ServerRequest, github: GitHubClient) -> json {
    let q = query(req.url);
    let context = workspace_context(auth, req, q.get("run") ?? "");
    let run = workspace_run(context);
    let _ = workspace_access(auth, context);
    let files = baml.json.to<json[]>(if (field(context,"files") != null) {field(context,"files")} else {workspace_snapshot(auth,field(context,"actor"),run,github)});
    let file = files.find((f) -> {str(f,"id") == (q.get("file") ?? "")});
    require(file != null,404,"file_not_found");
    workspace_file(github, run, file)
}

function workspace_file(github: GitHubClient, run: StoredRun, file: json) -> json {
    let change = field(file,"change");
    require(change != null,422,"github_diff_limit_open_on_github");
    let path = str(file,"id");
    let old_path = baml.json.to<string?>(field(change,"previous_filename")) ?? path;
    let original = spawn { if (field(change,"status") == "added") {""} else {workspace_blob(github,run,old_path,run.authorized.merge_base)} };
    let modified = spawn { if (field(change,"status") == "removed") {""} else {workspace_blob(github,run,path,run.authorized.identity.head)} };
    {"original":await original,"modified":await modified}
}

function workspace_blob(github: GitHubClient, run: StoredRun, path: string, revision: string) -> string {
    let e = run.authorized.enrollment;
    let key = baml.json.stringify({"tenant":e.tenant_id,"repository":e.repository_id,"revision":revision,"path":path});
    baml.json.to<string>(github.contents.get(key,3600,() -> {
        let token = github.installation_token(e);
        baml.json.from(workspace_text(github,e.repository,path,revision,token))
    }))
}

function workspace_text(github: GitHubClient, repository: string, path: string, revision: string, token: string) -> string {
    let data = github.api("GET",repository,"/contents/" + path.split("/").map((s) -> {url_encode(s)}).join("/") + "?ref=" + revision,token);
    require(field(data,"encoding") == "base64" && num(data,"size") <= 1000000,422,"large_or_binary_file_open_on_github");
    let content = uint8array.from_base64(str(data,"content").replace_all("\n", "")).to_string();
    require(!content.includes("\u0000"),422,"binary_file_open_on_github");
    content
}

function workspace_run(context: json) -> StoredRun {
    let run = baml.json.to<StoredRun>(field(context,"run"));
    run.authorized.enrollment = baml.json.to<Enrollment>(field(context,"enrollment"));
    run
}

function workspace_token(auth: BrowserAuth, context: json) -> string {
    let actor = baml.json.to<Actor>(field(context,"actor"));
    let e = baml.json.to<Enrollment>(field(context,"enrollment"));
    auth.secrets.open(str(context,"encrypted_token"),"github-user:" + actor.user_id + ":" + e.repository_id)
}
