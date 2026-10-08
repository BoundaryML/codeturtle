class SetupOptions {
    owners: string[],
    create_pr: bool,
}

class Onboarding {
    auth: BrowserAuth,
    github: GitHubClient,
    store: RunStore,
    action_ref: string,
    runtime_url: string,
    runtime_sha256: string,
    function preview(self, repository_id: string, owners: string[]) -> map<string, string> {
        require(
            owners.length() > 0
                && owners.every((o) -> {
                    matches(o, "^@[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)?$")
                }),
            400,
            "confirmed_owners_required",
        );
        require(
            matches(self.action_ref, "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/cli@[0-9a-f]{40}$")
                && matches(self.runtime_sha256, "^[0-9a-f]{64}$")
                && self.runtime_url.starts_with("https://")
                && !self.runtime_url.includes("\n")
                && !self.runtime_url.includes("'"),
            503,
            "release_not_configured",
        );
        let files = {
            ".github/workflows/codeturtle.yml": setup_workflow(self.action_ref, self.auth.origin, self.runtime_url, self.runtime_sha256),
        };
        let e = self.store.enrollment(repository_id);
        let token = self.github.installation_token(e);
        let repo = self.github.api("GET", e.repository, "", token);
        let tree = self.github.api(
            "GET",
            e.repository,
            "/git/trees/" + url_encode(str(repo, "default_branch")) + "?recursive=1",
            token,
        );
        require(field(tree, "truncated") != true, 409, "repository_tree_too_large");
        let paths = baml.json.to<json[]>(field(tree, "tree")).map((p) -> {
            str(p, "path")
        });
        require(
            !paths.includes(".github/workflows/codeturtle.yml"),
            409,
            "workflow_already_exists_verify_setup",
        );
        if (!paths.includes("CODETURTLE.md") && !paths.includes(".github/codeturtle/OWNERS")) {
            files["CODETURTLE.md"]
                = "# CodeTurtle review rules\n\n```codeturtle\n* " + owners.join(" ") + "\n```\n";
        }
        files
    }
    function create_setup_pr(
        self,
        req: baml.http.ServerRequest,
        repository_id: string,
        options: SetupOptions,
    ) -> json {
        let actor = self.auth.authorize(req, repository_id, setup = true);
        let e = self.store.enrollment(repository_id);
        let existing = self.store.rpc("setup_get", { "repository_id": repository_id });
        if (existing != null && field(existing, "pr") != null) {
            if (options.create_pr) {
                let number = num(field(existing, "pr"), "number");
                let token = self.github.installation_token(e, write = true);
                let pr = self.github.api("GET", e.repository, `/pulls/${number}`, token);
                if (str(pr, "state") == "closed" && field(pr, "merged") != true) {
                    let _ = self.github.api(
                        "PATCH",
                        e.repository,
                        `/pulls/${number}`,
                        token,
                        body = { "state": "open" },
                    );
                }
            }
            return existing;
        }
        let files = if (existing != null) {
            baml.json.to<map<string, string>>(field(existing, "files"))
        } else {
            self.preview(repository_id, options.owners)
        };
        if (!options.create_pr) {
            let manual: json = { "stage": "installed", "pr": null, "files": baml.json.from(files), "manual": true };
            return self.store.rpc("setup_save", { "repository_id": repository_id, "state": manual });
        }
        // A user explicitly requested a setup PR. The App must already have the permissions.
        let ref = ensure_setup_pr(self.github, e, files);
        let state: json = {
            "stage": "setup_pr_open",
            "pr": ref,
            "files": baml.json.from(files),
            "actor": actor.user_id,
        };
        self.store.rpc("setup_save", { "repository_id": repository_id, "state": state })
    }
    function verify_setup(self, req: baml.http.ServerRequest, repository_id: string) -> json {
        let _ = self.auth.authorize(req, repository_id);
        let e = self.store.enrollment(repository_id);
        let state = self.store.rpc("setup_get", { "repository_id": repository_id });
        if (state == null) {
            return { "stage": "installed" };
        }
        let stage = "awaiting_first_run";
        if (field(state, "pr") != null) {
            let pr_number = num(field(state, "pr"), "number");
            let pr = self.github.api(
                "GET",
                e.repository,
                `/pulls/${pr_number}`,
                self.github.installation_token(e),
            );
            stage
                = if (field(pr, "merged") == true) {
                    "awaiting_first_run"
                } else if (str(pr, "state") == "closed") {
                    "action_required"
                } else {
                    "setup_pr_open"
                };
        }
        if (stage == "awaiting_first_run") {
            let token = self.github.installation_token(e);
            let repo = self.github.api("GET", e.repository, "", token);
            let branch = str(repo, "default_branch");
            let workflow = self.github.api(
                "GET",
                e.repository,
                "/contents/.github/workflows/codeturtle.yml?ref=" + url_encode(branch),
                token,
            ) catch_all (error) {
                let e: ApiError => {
                    if (e.status == 404) {
                        return {
                            "stage": "action_required",
                            "message": "Add the previewed workflow to the default branch, then verify again",
                            "files": field(state, "files"),
                        };
                    }
                    throw e
                },
                _ => throw error,
            };
            let actual = uint8array.from_base64(str(workflow, "content").replace_all("\n", "")).to_string();
            require(
                actual == str(field(state, "files"), ".github/workflows/codeturtle.yml"),
                409,
                "setup_workflow_changed",
            );
            let _ = self.github.api(
                "GET",
                e.repository,
                "/contents/CODETURTLE.md?ref=" + url_encode(branch),
                token,
            ) catch (error) {
                let err: ApiError => {
                    if (err.status != 404) {
                        throw err;
                    }
                    self.github.api(
                        "GET",
                        e.repository,
                        "/contents/.github/codeturtle/OWNERS?ref=" + url_encode(branch),
                        token,
                    )
                },
            };
            let _ = self.store.rpc(
                "trust_workflow",
                {
                    "repository_id": repository_id,
                    "workflow_ref": e.repository + "/.github/workflows/codeturtle.yml@refs/heads/" + branch,
                    "workflow_blob": str(workflow, "sha"),
                },
            );
            let connected = self.store.rpc("connected", { "repository_id": repository_id });
            if (connected != null) {
                stage = "connected";
            }
        }
        { "stage": stage, "pr": field(state, "pr") }
    }
}

function setup_workflow(
    action_ref: string,
    origin: string,
    runtime_url: string,
    runtime_sha: string,
) -> string {
    "name: CodeTurtle\non:\n  pull_request_target:\n    types: [opened, synchronize, reopened, edited]\npermissions:\n  contents: read\n  id-token: write\nconcurrency:\n  group: codeturtle-${{ github.event.pull_request.number }}\n  cancel-in-progress: true\njobs:\n  codeturtle:\n    runs-on: ubuntu-latest\n    timeout-minutes: 30\n    steps:\n      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683\n        with:\n          ref: ${{ github.event.pull_request.base.sha }}\n          fetch-depth: 0\n          persist-credentials: false\n      - name: Fetch PR history without checking out PR code\n        env:\n          PR_NUMBER: ${{ github.event.pull_request.number }}\n          GH_TOKEN: ${{ github.token }}\n        run: |\n          auth=$(printf 'x-access-token:%s' \"$GH_TOKEN\" | base64 -w0)\n          git -c http.extraheader=\"AUTHORIZATION: basic $auth\" fetch --no-tags origin \"refs/pull/$PR_NUMBER/head\"\n      - uses: "
        + action_ref
        + "\n        with:\n          api-url: '"
        + origin
        + "'\n          runtime-url: '"
        + runtime_url
        + "'\n          runtime-sha256: '"
        + runtime_sha
        + "'\n"
}

function ensure_setup_pr(github: GitHubClient, e: Enrollment, files: map<string, string>) -> json {
    let jwt = github.crypto.sign(github.app_id, github.private_key);
    let token = str(
        github.http.send(
            "POST",
            `https://api.github.com/app/installations/${e.installation_id}/access_tokens`,
            jwt,
            {
                "repository_ids": [baml.Int.parse(e.repository_id)],
                "permissions": { "contents": "write", "workflows": "write", "pull_requests": "write" },
            },
        ),
        "token",
    );
    let repo = github.api("GET", e.repository, "", token);
    let branch = "codeturtle/setup-v1";
    let existing = baml.json.to<json[]>(
        github.api(
            "GET",
            e.repository,
            "/pulls?state=open&head=" + url_encode(e.repository.split("/")[0] + ":" + branch),
            token,
        ),
    );
    if (existing.length() > 0) {
        require(num(field(existing[0], "user"), "id") == github.bot_id, 409, "setup_branch_conflict");
        let remote = github.api("GET", e.repository, "/git/trees/" + url_encode(branch) + "?recursive=1", token);
        let remote_entries = baml.json.to<json[]>(field(remote, "tree"));
        for (let path in files.keys()) {
            let entry = remote_entries.find((item) -> {
                str(item, "path") == path
            })
                ?? throw ApiError {status: 409, code: "setup_files_changed"};
            let blob = github.api("GET", e.repository, "/git/blobs/" + str(entry, "sha"), token);
            require(
                uint8array.from_base64(str(blob, "content").replace_all("\n", "")).to_string()
                    == files[path],
                409,
                "setup_files_changed",
            );
        }
        return { "number": num(existing[0], "number"), "url": str(existing[0], "html_url") };
    }
    let base_branch = str(repo, "default_branch");
    let base = github.api("GET", e.repository, "/git/ref/heads/" + url_encode(base_branch), token);
    let sha = str(field(base, "object"), "sha");
    let commit = github.api("GET", e.repository, "/git/commits/" + sha, token);
    let entries: json[] = [];
    for (let path in files.keys()) {
        entries.push({ "path": path, "mode": "100644", "type": "blob", "content": files[path] });
    }
    let tree = github.api(
        "POST",
        e.repository,
        "/git/trees",
        token,
        body = { "base_tree": str(field(commit, "tree"), "sha"), "tree": entries },
    );
    let created = github.api(
        "POST",
        e.repository,
        "/git/commits",
        token,
        body = { "message": "Add CodeTurtle review workflow", "tree": str(tree, "sha"), "parents": [sha] },
    );
    // Never force a ref or mutate the default branch. A conflicting branch is surfaced.
    let _ = github.api(
        "POST",
        e.repository,
        "/git/refs",
        token,
        body = { "ref": "refs/heads/" + branch, "sha": str(created, "sha") },
    ) catch_all (_) {
        _ => {
            let remote = github.api("GET", e.repository, "/git/ref/heads/" + url_encode(branch), token);
            let remote_commit = github.api(
                "GET",
                e.repository,
                "/git/commits/" + str(field(remote, "object"), "sha"),
                token,
            );
            require(
                str(field(remote_commit, "tree"), "sha") == str(tree, "sha"),
                409,
                "setup_branch_conflict",
            );
            remote
        },
    };
    let pr = github.api(
        "POST",
        e.repository,
        "/pulls",
        token,
        body = {
            "title": "Set up CodeTurtle",
            "head": branch,
            "base": base_branch,
            "body": "Adds one CodeTurtle job. Review the workflow and confirmed owners before merging. Automated evaluation is separate from human approval.",
        },
    ) catch_all (_) {
        _ => {
            let found = baml.json.to<json[]>(
                github.api(
                    "GET",
                    e.repository,
                    "/pulls?state=open&head="
                        + url_encode(e.repository.split("/")[0] + ":" + branch),
                    token,
                ),
            );
            let result = found.at(0) ?? throw ApiError {status: 503, code: "setup_pr_not_confirmed"};
            require(num(field(result, "user"), "id") == github.bot_id, 409, "setup_branch_conflict");
            result
        },
    };
    { "number": num(pr, "number"), "url": str(pr, "html_url") }
}

test "Setup workflow uses trusted base and one job" {
    let workflow = setup_workflow(
        "owner/repo/cli@" + "a".repeat(40),
        "https://turtle.example",
        "https://example.test/runtime",
        "b".repeat(64),
    );
    assert.contains(workflow, "pull_request_target");
    assert.contains(workflow, "persist-credentials: false");
    assert.contains(workflow, "ref: ${{ github.event.pull_request.base.sha }}")
}

function start_setup(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    client_id: string,
) -> baml.http.Response {
    let session = auth.session(req);
    let q = query(req.url);
    let review_id = q.get("run");
    let target = if (review_id != null) {
        require(matches(review_id, "^[a-f0-9-]{36}$"), 400, "invalid_run");
        auth.store.rpc("review_link_target", { "id": review_id, "actor": field(session, "actor") })
    } else {
        null
    };
    let installation = if (target != null) {
        str(target, "installation_id")
    } else {
        q.get("installation_id") ?? ""
    };
    let repository = if (target != null) {
        str(target, "repository_id")
    } else {
        q.get("repository_id") ?? ""
    };
    require(
        matches(installation, "^[1-9][0-9]*$") && matches(repository, "^[1-9][0-9]*$"),
        400,
        "installation_and_repository_required",
    );
    let state = secret();
    let _ = auth.store.rpc(
        "oauth_put",
        {
            "hash": sha256(state),
            "purpose": "github",
            "data": {
                "actor": field(session, "actor"),
                "installation_id": installation,
                "repository_id": repository,
                "review_id": review_id,
                "next": safe_return(q.get("next") ?? "/"),
            },
            "expires_at": now() + 600,
        },
    );
    redirect(
        "https://github.com/login/oauth/authorize?client_id="
            + url_encode(client_id)
            + "&redirect_uri="
            + url_encode(auth.origin + "/auth/github/callback")
            + "&state="
            + state,
        set_cookie = "__Host-ct_github=" + state + "; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=600",
    )
}

function complete_setup(
    auth: BrowserAuth,
    req: baml.http.ServerRequest,
    github: GitHubClient,
    secrets: SecretBox,
    client_id: string,
    client_secret: string,
) -> baml.http.Response {
    let q = query(req.url);
    let state = q.get("state") ?? "";
    require(state.length() == 64 && cookie(req, "__Host-ct_github") == state, 403, "invalid_setup_state");
    let data = auth.store.rpc("oauth_take", { "hash": sha256(state), "purpose": "github" });
    let session = auth.session(req);
    require(field(session, "actor") == field(data, "actor"), 403, "setup_actor_mismatch");
    let exchange = github.http.send(
        "POST",
        "https://github.com/login/oauth/access_token",
        "",
        {
            "client_id": client_id,
            "client_secret": client_secret,
            "code": q.get("code") ?? "",
            "redirect_uri": auth.origin + "/auth/github/callback",
        },
    );
    let token = str(exchange, "access_token");
    let user = github.http.send("GET", "https://api.github.com/user", token, null);
    let installation_id = str(data, "installation_id");
    let repository_id = str(data, "repository_id");
    let page = 1;
    let selected: json = null;
    while (page <= 100) {
        let repos = github.http.send(
            "GET",
            `https://api.github.com/user/installations/${installation_id}/repositories?per_page=100&page=${page}`,
            token,
            null,
        );
        let list = baml.json.to<json[]>(field(repos, "repositories"));
        for (let r in list) {
            if (num(r, "id").to_string() == repository_id) {
                selected = r;
            }
        }
        if (selected != null || list.length() < 100) {
            break;
        }
        page += 1;
    }
    if (field(data, "review_id") != null) {
        require(
            selected != null && field(field(selected, "permissions"), "pull") == true,
            403,
            "repository_access_required",
        );
        let actor = baml.json.to<Actor>(field(session, "actor"));
        let _ = auth.store.rpc(
            "link_reviewer",
            {
                "actor": baml.json.from(actor),
                "repository_id": repository_id,
                "installation_id": installation_id,
                "github_user_id": num(user, "id").to_string(),
                "encrypted_token": secrets.seal(token, "github-user:" + actor.user_id + ":" + repository_id),
            },
        );
        return redirect(safe_return(baml.json.to<string?>(field(data, "next")) ?? "/"));
    }
    require(
        selected != null && field(field(selected, "permissions"), "admin") == true,
        403,
        "repository_admin_required",
    );
    let actor = baml.json.to<Actor>(field(session, "actor"));
    let repository = str(selected, "full_name");
    let enrolled = Enrollment {
        repository_id: repository_id,
        repository: repository,
        tenant_id: actor.tenant_id,
        installation_id: baml.Int.parse(installation_id),
        workflow_ref: repository
            + "/.github/workflows/codeturtle.yml@refs/heads/"
            + str(selected, "default_branch"),
        workflow_blob: "",
        active: true,
        slack: null,
    };
    let _ = auth.store.rpc(
        "link_repository",
        {
            "actor": baml.json.from(actor),
            "enrollment": baml.json.from(enrolled),
            "github_user_id": num(user, "id").to_string(),
            "encrypted_token": secrets.seal(token, "github-user:" + actor.user_id + ":" + repository_id),
        },
    );
    redirect("/?repository=" + repository_id)
}
