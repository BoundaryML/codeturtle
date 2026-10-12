class DiffTestStore {
    run: StoredRun,
    encrypted_token: string,
    implements RunStore {
        function rpc(self, name: string, payload: json) -> json {
            match (name) {
                "session_get" => ({ "actor": { "user_id": "reader", "tenant_id": "tenant" } }),
                "review_run" => baml.json.from(self.run),
                "authorize" => ({ "encrypted_token": self.encrypted_token }),
                "enrollment" => baml.json.from(self.run.authorized.enrollment),
                _ => throw `Unexpected database call: ${name}`,
            }
        }
    }
}

class DiffTestTransport {
    files: json[],
    allowed: bool,
    comparisons: int,
    implements Transport {
        function send(self, method: string, url: string, token: string, payload: json) -> json {
            assert.equal(method, "GET");
            if (url == "https://api.github.com/repos/acme/repo") {
                assert.equal(token, "reader-token");
                return { "id": 42, "permissions": { "pull": self.allowed } };
            }
            assert.equal(
                url,
                "https://api.github.com/repos/acme/repo/compare/merge-base...stored-head?per_page=1",
            );
            assert.equal(token, "installation-token");
            self.comparisons += 1;
            { "files": baml.json.from(self.files) }
        }
    }
}

class DiffTestFixture {
    auth: BrowserAuth,
    github: GitHubClient,
    http: DiffTestTransport,
    function request(self, suffix: string) -> json {
        review_diff(
            self.auth,
            baml.http.ServerRequest {
                method: "GET",
                url: "/api/review/diff?" + suffix,
                headers: { "cookie": "__Host-ct_session=" + "a".repeat(64) },
                body: "",
            },
            self.github,
        )
    }
}

function diff_test_fixture(files: json[], allowed: bool = true) -> DiffTestFixture {
    let identity = RunIdentity {
        repository_id: "42",
        repository: "acme/repo",
        pr: 7,
        run_id: "123",
        run_attempt: 1,
        head: "stored-head",
        base: "base",
        policy: "base",
    };
    let enrollment = Enrollment {
        repository_id: "42",
        repository: "acme/repo",
        tenant_id: "tenant",
        installation_id: 9,
        workflow_ref: "workflow",
        workflow_blob: "blob",
        active: true,
        slack: null,
    };
    let run = StoredRun {
        id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        authorized: AuthorizedRun {
            identity: identity,
            enrollment: enrollment,
            merge_base: "merge-base",
            title: "Test PR",
        },
        expires_at: 0,
        digest: null,
        accepted_at: null,
        deliveries: null,
        envelope: ReportEnvelope {
            schema_version: 1,
            cli_version: "test",
            run_id: "test",
            identity: identity,
            setup_failure: null,
            report: { "requirements": [{ "path": "other.txt" }, { "path": "target.txt" }] },
        },
    };
    let secrets = SecretBox { key: uint8array.zeroes(32) };
    let store = DiffTestStore {
        run: run,
        encrypted_token: secrets.seal("reader-token", "github-user:reader:42"),
    };
    let http = DiffTestTransport { files: files, allowed: allowed, comparisons: 0 };
    let tokens = bounded_cache(4096);
    let key = baml.json.stringify(
        { "tenant": "tenant", "installation": 9, "repository": "42", "write": false },
    );
    let _ = tokens.get(key, 3000, () -> {
        let value: json = { "token": "installation-token" };
        value
    });
    DiffTestFixture {
        auth: BrowserAuth {
            store: store,
            http: http,
            origin: "https://example.test",
            client_id: "test",
            client_secret: "test",
            organization_id: null,
            secrets: secrets,
        },
        github: GitHubClient {
            http: http,
            crypto: CryptoHelper { python: "unused", path: "unused" },
            app_id: "test",
            private_key: "unused",
            bot_id: 1,
            tokens: tokens,
            contents: bounded_cache(4096),
        },
        http: http,
    }
}

test "Review diff selects requirement path and immutable commits" {
    let fixture = diff_test_fixture(
        [
            { "filename": "target.txt", "patch": "@@ -1 +1 @@\n-before\n+after" },
            { "filename": "other.txt", "patch": "wrong" },
        ],
    );
    let result = fixture.request("run=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa&index=1");
    assert.equal(field(result, "patch"), "@@ -1 +1 @@\n-before\n+after");
    assert.equal(fixture.http.comparisons, 1);
}

test "Review diff falls back for missing files and absent patches" {
    let missing = diff_test_fixture([]).request("run=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa&index=1");
    assert.equal(field(missing, "patch"), null);
    assert.equal(
        str(missing, "message"),
        "Diff is outside GitHub's response limit. Open the PR files on GitHub.",
    );
    let binary = diff_test_fixture([{ "filename": "target.txt" }]).request(
        "run=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa&index=1",
    );
    assert.equal(field(binary, "patch"), null);
    assert.equal(str(binary, "message"), "Binary or large files may require viewing on GitHub.");
}

test "Review diff rejects invalid selection and revoked access" {
    let fixture = diff_test_fixture([]);
    for (
        let suffix in [
            "run=bad&index=0",
            "run=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa&index=-1",
            "run=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa&index=2",
        ]
    ) {
        let status = {
            fixture.request(suffix);
            200
        } catch_all (e) {
            let error: ApiError => error.status,
            _ => 500
        };
        assert.equal(status, 400);
    }
    assert.equal(fixture.http.comparisons, 0);
    let denied = diff_test_fixture([], allowed = false);
    let status = {
        denied.request("run=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa&index=1");
        200
    } catch_all (e) {
        let error: ApiError => error.status,
        _ => 500
    };
    assert.equal(status, 403);
    assert.equal(denied.http.comparisons, 0);
}
