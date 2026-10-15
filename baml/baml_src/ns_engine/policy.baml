// CODETURTLE.md policy parsing. All recoverable problems are collected
// as Diagnostics with 1-based line numbers in the markdown file.

function policy_source_name() -> string {
    "CODETURTLE.md"
}

class PolicyParse {
    policy: root.Policy?,
    diagnostics: root.Diagnostic[],
}

class PolicyBlock {
    lines: string[],
    start_line: int,
}

function extract_policy_block(markdown: string) -> PolicyBlock? throws root.CliError {
    let lines = markdown.lines();
    let found: string[] = [];
    let start_line = 0;
    let blocks = 0;
    let inside = false;
    let i = 0;
    while (i < lines.length()) {
        let line = lines[i].trim();
        if (inside) {
            if (line.starts_with("```")) {
                inside = false;
            } else {
                found.push(lines[i]);
            }
        } else if (line == "```codeturtle") {
            blocks = blocks + 1;
            inside = true;
            start_line = i + 2;
        }
        i = i + 1;
    }
    if (inside) {
        throw root.CliError.new(root.ErrorCode.InvalidPolicyBlock, "codeturtle block is not closed");
    }
    match (blocks) {
        0 => null,
        1 => PolicyBlock { lines: found, start_line: start_line },
        _ => {
            throw root.CliError.new(root.ErrorCode.InvalidPolicyBlock, `expected one codeturtle block, found ${blocks}`)
        },
    }
}

function is_valid_function_name(name: string) -> bool {
    let parts = name.split(".");
    if (parts.length() < 2) {
        return false;
    }
    parts.every((p: string) -> bool {
        !p.is_empty()
            && p.chars().every((c: string) -> bool {
                c.is_ascii_lowercase() || c.is_ascii_numeric() || c == "_"
            })
    })
}

function split_rule_comment(line: string) -> string[] {
    match (line.index_of("#")) {
        null => [line, ""],
        let idx: int => [line.slice(0, idx), line.slice(idx, line.length())],
    }
}

function parse_rule_line(
    raw_line: string,
    line_number: int,
    rules: root.Rule[],
    diagnostics: root.Diagnostic[],
) -> null {
    let trimmed = raw_line.trim();
    if (trimmed.is_empty()) {
        return null;
    }
    let parts = split_rule_comment(raw_line);
    let head = parts[0].trim();
    let comment = parts[1].trim();
    let threshold: root.Threshold = "any";
    let condition: string? = null;
    let seen_all = false;
    let seen_when = false;
    if (!comment.is_empty()) {
        if (!comment.starts_with("# codeturtle:")) {
            diagnostics.push(
                root.Diagnostic.new(
                    root.ErrorCode.UnknownDirective,
                    `unsupported comment "${comment}"; directives use "# codeturtle:"`,
                    policy_source_name(),
                    line_number,
                ),
            );
            return null;
        }
        let directives = comment.slice("# codeturtle:".length(), comment.length()).trim();
        for (let token in directives.split(" ")) {
            let tok = token.trim();
            if (tok.is_empty()) {
                continue;
            }
            if (tok == "all") {
                if (seen_all) {
                    diagnostics.push(
                        root.Diagnostic.new(
                            root.ErrorCode.UnknownDirective,
                            "duplicate `all` directive",
                            policy_source_name(),
                            line_number,
                        ),
                    );
                }
                seen_all = true;
                threshold = "all";
            } else if (tok.starts_with("when=")) {
                if (seen_when) {
                    diagnostics.push(
                        root.Diagnostic.new(
                            root.ErrorCode.UnknownDirective,
                            "duplicate `when=` directive",
                            policy_source_name(),
                            line_number,
                        ),
                    );
                }
                seen_when = true;
                let name = tok.slice("when=".length(), tok.length());
                if (is_valid_function_name(name)) {
                    condition = name;
                } else {
                    diagnostics.push(
                        root.Diagnostic.new(
                            root.ErrorCode.InvalidPolicy,
                            `invalid function name "${name}"`,
                            policy_source_name(),
                            line_number,
                        ),
                    );
                }
            } else {
                diagnostics.push(
                    root.Diagnostic.new(
                        root.ErrorCode.UnknownDirective,
                        `${tok} is not supported`,
                        policy_source_name(),
                        line_number,
                    ),
                );
            }
        }
    }
    let tokens = head.split(" ").filter((t: string) -> bool {
        !t.trim().is_empty()
    });
    if (tokens.length() < 2) {
        diagnostics.push(
            root.Diagnostic.new(
                root.ErrorCode.InvalidPolicy,
                "rule needs a path pattern and at least one owner",
                policy_source_name(),
                line_number,
            ),
        );
        return null;
    }
    let pattern = tokens[0];
    root.lib.paths.PathPattern.compile(pattern) catch (e) {
        root.CliError => {
            diagnostics.push(
                root.Diagnostic.new(e.code, e.message, policy_source_name(), line_number),
            );
            return null;
        },
    };
    let owners: root.Owner[] = [];
    let j = 1;
    while (j < tokens.length()) {
        let tok = tokens[j].trim();
        let owner = root.lib.owners.parse_owner(tok) catch (e) {
            root.CliError => {
                diagnostics.push(
                    root.Diagnostic.new(e.code, e.message, policy_source_name(), line_number),
                );
                null
            },
        };
        match (owner) {
            null => null,
            let o: root.Owner => owners.push(o),
        };
        j = j + 1;
    }
    if (owners.length() == 0) {
        return null;
    }
    rules.push(
        root.Rule {
            pattern: pattern,
            owners: owners,
            threshold: threshold,
            condition: condition,
            line: line_number,
            raw: raw_line.trim(),
        },
    );
    null
}

function parse_policy(markdown: string) -> PolicyParse {
    let block = extract_policy_block(markdown) catch (e) {
        root.CliError => {
            return PolicyParse {
                policy: null,
                diagnostics: [root.Diagnostic.new(e.code, e.message, policy_source_name(), null)],
            };
        },
    };
    match (block) {
        null => {
            PolicyParse {
                policy: null,
                diagnostics: [
                    root.Diagnostic.new(
                        root.ErrorCode.InvalidPolicyBlock,
                        "no codeturtle block found",
                        policy_source_name(),
                        null,
                    ),
                ],
            }
        },
        let b: PolicyBlock => {
            let rules: root.Rule[] = [];
            let diagnostics: root.Diagnostic[] = [];
            let i = 0;
            while (i < b.lines.length()) {
                parse_rule_line(b.lines[i], b.start_line + i, rules, diagnostics);
                i = i + 1;
            }
            if (diagnostics.length() == 0) {
                PolicyParse {
                    policy: root.Policy {
                        rules: rules,
                        digest: root.lib.digest.Digest.sha256_hex(b.lines.join("\n")),
                    },
                    diagnostics: diagnostics,
                }
            } else {
                PolicyParse { policy: null, diagnostics: diagnostics }
            }
        },
    }
}

test "parses example policy" {
    let md = "# Review policy\n\n```codeturtle\n/stdlib/ @alice @bob # codeturtle: all\n* @example/security # codeturtle: when=checks.adds_environment_access\n```\n";
    let parsed = parse_policy(md);
    assert.is_true(parsed.diagnostics.length() == 0);
    let policy = match (parsed.policy) {
        null => throw root.CliError.new(root.ErrorCode.InvalidPolicy, "expected policy"),
        let p: root.Policy => p,
    };
    assert.equal(policy.rules.length(), 2);
    assert.equal(policy.rules[0].threshold, "all");
    assert.equal(policy.rules[0].line, 4);
    assert.equal(policy.rules[1].owner_handles()[0], "@example/security")
}

test "collects unknown directive" {
    let md = "```codeturtle\n* @alice # codeturtle: approve_automatically\n```\n";
    let parsed = parse_policy(md);
    assert.equal(parsed.diagnostics.length(), 1);
    assert.equal(string.from(parsed.diagnostics[0].code), "unknown_directive")
}

test "empty policy is valid" {
    let parsed = parse_policy("```codeturtle\n\n```\n");
    assert.is_true(parsed.diagnostics.length() == 0)
}
