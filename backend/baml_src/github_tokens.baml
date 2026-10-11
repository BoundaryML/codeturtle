// The encrypted membership value holds the whole rotating credential. Legacy
// access-only values continue to work until GitHub requires reconnection.
function github_token_bundle(exchange: json) -> string {
    let access = str(exchange, "access_token");
    require(access.length() > 0, 403, "github_reconnect_required");
    let expires = baml.json.to<int?>(field(exchange, "expires_in"));
    let refresh_expires = baml.json.to<int?>(field(exchange, "refresh_token_expires_in"));
    baml.json.stringify({"access_token": access, "refresh_token": field(exchange, "refresh_token"),
        "expires_at": if (expires == null) { null } else { now() + expires },
        "refresh_expires_at": if (refresh_expires == null) { null } else { now() + refresh_expires }})
}

function github_membership_token(auth: BrowserAuth, actor: Actor, repository_id: string, encrypted: string) -> string {
    let scope = "github-user:" + actor.user_id + ":" + repository_id;
    let plain = auth.secrets.open(encrypted, scope);
    if (!plain.starts_with("{")) { return plain; }
    let bundle = baml.json.parse(plain);
    let expiry = baml.json.to<int?>(field(bundle, "expires_at"));
    if (if (expiry == null) { true } else { expiry > now() + 300 }) { return str(bundle, "access_token"); }
    let refresh = baml.json.to<string?>(field(bundle, "refresh_token"));
    let refresh_expiry = baml.json.to<int?>(field(bundle, "refresh_expires_at"));
    require(refresh != null && (if (refresh_expiry == null) { true } else { refresh_expiry > now() + 30 }), 403, "github_reconnect_required");
    // One-use token: a claim is never stolen or retried after a timeout. An
    // ambiguous provider outcome must reconnect instead of rotating twice.
    let claim = github_refresh_claim(auth.store, actor, repository_id, encrypted);
    if (field(claim, "state") == "updated") {
        let current = baml.json.parse(auth.secrets.open(str(claim, "encrypted_token"), scope));
        let current_expiry = baml.json.to<int?>(field(current, "expires_at"));
        require(if (current_expiry == null) { true } else { current_expiry > now() + 30 }, 403, "github_reconnect_required");
        return str(current, "access_token");
    }
    let exchange = auth.http.send("POST", "https://github.com/login/oauth/access_token", "", {
        "client_id": config("CODETURTLE_GITHUB_CLIENT_ID"), "client_secret": config("CODETURTLE_GITHUB_CLIENT_SECRET"),
        "grant_type": "refresh_token", "refresh_token": refresh,
    });
    require(field(exchange, "error") == null, 403, "github_reconnect_required");
    let replacement = auth.secrets.seal(github_token_bundle(exchange), scope);
    let _ = auth.store.rpc("github_refresh_commit", {"actor": baml.json.from(actor), "repository_id": repository_id,
        "encrypted_token": encrypted, "claim": field(claim, "claim"), "replacement": replacement});
    str(exchange, "access_token")
}

test "OAuth bundle retains refresh credential and expiry" {
    let before = now();
    let value = baml.json.parse(github_token_bundle({"access_token":"access", "refresh_token":"refresh", "expires_in":28800,"refresh_token_expires_in":15897600}));
    assert.equal(field(value,"refresh_token"), "refresh");
    assert.equal(num(value,"expires_at") >= before + 28800, true);
    assert.equal(field(baml.json.parse(github_token_bundle({"access_token":"non-expiring"})),"expires_at"), null)
}

function github_refresh_claim(store: RunStore, actor: Actor, repository_id: string, encrypted: string) -> json {
    let attempt = 0;
    while (true) {
        let result = store.rpc("github_refresh_claim", {"actor":baml.json.from(actor), "repository_id":repository_id, "encrypted_token":encrypted}) catch (error) {
            let e: ApiError => {
                if (e.code != "github_refresh_in_progress" || attempt >= 12) { throw e; }
                let waiting: json = null;
                waiting
            }
        };
        if (result != null) { return result; }
        attempt += 1;
        baml.sys.sleep(baml.time.Duration.from_milliseconds(250));
    }
    throw ApiError {status:503,code:"github_refresh_in_progress"}
}
