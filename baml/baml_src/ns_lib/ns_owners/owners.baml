// Owner handles: `@user` or `@org/team`, GitHub login character rules.

function is_valid_login(name: string) -> bool {
    !name.is_empty()
        && name.length() <= root.lib.limits.Limits.max_login_length()
        && !name.starts_with("-")
        && !name.ends_with("-")
        && name.chars().every((c: string) -> bool {
            c.is_ascii_alphanumeric() || c == "-"
        })
}

function parse_owner(token: string) -> root.Owner throws root.CliError {
    if (!token.starts_with("@")) {
        throw root.CliError.new(root.ErrorCode.InvalidPolicy, `owner "${token}" must start with "@"`);
    }
    let body = token.slice(1, token.length());
    let parts = body.split("/");
    match (parts.length()) {
        1 => {
            if (is_valid_login(body)) {
                root.UserOwner { handle: body }
            } else {
                throw root.CliError.new(root.ErrorCode.InvalidPolicy, `invalid user handle "${token}"`)
            }
        },
        2 => {
            let org = parts[0];
            let team = parts[1];
            if (is_valid_login(org) && is_valid_login(team)) {
                root.TeamOwner { org: org, team: team }
            } else {
                throw root.CliError.new(root.ErrorCode.InvalidPolicy, `invalid team handle "${token}"`)
            }
        },
        _ => {
            throw root.CliError.new(root.ErrorCode.InvalidPolicy, `invalid owner handle "${token}"`)
        },
    }
}

test "owner parsing" {
    assert.equal(string.from(parse_owner("@alice")), "@alice");
    assert.equal(string.from(parse_owner("@example/security")), "@example/security");
    let bad = parse_owner("alice") catch (e) {
        root.CliError => e.code,
    };
    assert.equal(bad, root.ErrorCode.InvalidPolicy)
}
