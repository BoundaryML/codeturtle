function load_sources(directory: string, prefix: string = "") -> map<string, string> {
    let sources: map<string, string> = {};
    if (!baml.fs.exists(directory)) {
        return sources;
    }
    for (let entry in baml.fs.read_dir(directory)) {
        if (entry.is_symlink) {
            continue;
        }
        let relative = prefix + entry.name;
        let path = directory + "/" + entry.name;
        if (entry.is_dir) {
            let nested = load_sources(path, prefix = relative + "/");
            for (let key in nested.keys()) {
                sources[key] = nested[key];
            }
        } else if (entry.is_file && entry.name.ends_with(".baml")) {
            sources[relative] = baml.fs.read(path);
        }
    }
    sources
}

// Filesystem adapters. The policy engine itself accepts typed values and source maps.
function lint_policy(repo: string) -> LintReport {
    lint_sources(policy_rules(repo), load_sources(repo + "/.github/codeturtle"))
}

function run(repo: string, changes_path: string, concurrency: int) -> Report {
    let pr = baml.json.from_string<PullRequest>(baml.fs.read(changes_path));
    check_sources(pr, policy_rules(repo), load_sources(repo + "/.github/codeturtle"), concurrency = concurrency)
}

// Markdown prose is documentation. Only explicitly tagged rule fences execute.
// Blank lines preserve the source line numbers reported by the existing engine.
function markdown_rules(source: string) -> string {
    let lines: string[] = [];
    let fence = "";
    let rules = false;
    let found = false;
    for (let line in source.lines()) {
        let trimmed = line.trim();
        if (fence == "" && (trimmed.starts_with("```") || trimmed.starts_with("~~~"))) {
            fence = trimmed.slice(0, 3);
            rules = trimmed == fence + "codeturtle";
            found = found || rules;
            lines.push("");
        } else if (fence != "" && trimmed == fence) {
            fence = "";
            rules = false;
            lines.push("");
        } else {
            lines.push(
                if (rules) {
                    line
                } else {
                    ""
                },
            );
        }
    }
    if (fence != "" && rules) {
        throw "Unclosed codeturtle fence in CODETURTLE.md";
    }
    if (!found) {
        throw "CODETURTLE.md must contain a fenced codeturtle rules block";
    }
    lines.join("\n")
}

function policy_rules(repo: string) -> string {
    if (baml.fs.exists(repo + "/CODETURTLE.md")) {
        markdown_rules(baml.fs.read(repo + "/CODETURTLE.md"))
    } else {
        baml.fs.read(repo + "/.github/codeturtle/OWNERS")
    }
}

test "Markdown policies preserve rule lines and ignore prose and unrelated fences" {
    let source = "# Review policy\n\n```codeturtle\n* @alice\n/src/ @bob # codeturtle: all\n```\n```text\n* @mallory\n```";
    let parsed = parse_rules(markdown_rules(source));
    assert.equal(parsed.length(), 2);
    assert.equal(parsed[0].line, 4);
    assert.equal(parsed[1].owners, ["@bob"])
}

test "Malformed Markdown cannot silently fall back to legacy ownership" {
    let result = markdown_rules("```codeturtle\n* @alice") catch_all (_) {
        _ => "rejected"
    };
    assert.equal(result, "rejected")
}
