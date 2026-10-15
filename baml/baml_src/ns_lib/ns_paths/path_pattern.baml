// Repository paths and policy path patterns.
//
// Pattern grammar per product spec: case-sensitive, `/` separated,
// leading `/` anchors, `*`/`?` within a segment, whole `**` spans
// directories, trailing `/` matches descendants, bare `*` matches all.

class RepoPath {
    raw: string,

    function segments(self) -> string[] {
        self.raw.split("/")
    }

    function file_name(self) -> string {
        match (self.segments().at(-1)) {
            null => self.raw,
            let name: string => name,
        }
    }

    function display(self) -> string {
        self.raw.chars()
            .map((c: string) -> string {
                if (c.is_ascii_control()) {
                    "?"
                } else {
                    c
                }
            })
            .join("")
    }

    function parent(self) -> RepoPath? {
        match (self.raw.last_index_of("/")) {
            null => null,
            let idx: int => RepoPath { raw: self.raw.slice(0, idx) },
        }
    }

    function extension(self) -> string? {
        let name = self.file_name();
        match (name.last_index_of(".")) {
            null => null,
            let idx: int => {
                if (idx == 0) {
                    null
                } else {
                    name.slice(idx + 1, name.length())
                }
            },
        }
    }

    function file_stem(self) -> string {
        let name = self.file_name();
        match (self.extension()) {
            null => name,
            let ext: string => name.slice(0, name.length() - ext.length() - 1),
        }
    }
}

class PathPattern {
    raw: string,
    anchored: bool,
    segments: string[],

    function compile(raw: string) -> PathPattern throws root.CliError {
        if (raw.is_empty()) {
            throw root.CliError.new(root.ErrorCode.InvalidPolicy, "path pattern must not be empty");
        }
        if (raw == "*") {
            return PathPattern { raw: raw, anchored: false, segments: ["**"] };
        }
        let anchored = raw.starts_with("/");
        let body = if (anchored) {
            raw.slice(1, raw.length())
        } else {
            raw
        };
        let is_dir = body.ends_with("/");
        let trimmed = if (is_dir) {
            body.slice(0, body.length() - 1)
        } else {
            body
        };
        if (trimmed.is_empty()) {
            throw root.CliError.new(root.ErrorCode.InvalidPolicy, `path pattern "${raw}" has no segments`);
        }
        let segments = trimmed.split("/");
        for (let seg in segments) {
            match (seg) {
                "" => {
                    throw root.CliError.new(root.ErrorCode.InvalidPolicy, `path pattern "${raw}" contains an empty segment`)
                },
                "." => {
                    throw root.CliError.new(root.ErrorCode.InvalidPolicy, `path pattern "${raw}" contains "."`)
                },
                ".." => {
                    throw root.CliError.new(root.ErrorCode.InvalidPolicy, `path pattern "${raw}" contains ".."`)
                },
                _ => null,
            };
            if (seg.includes("**") && seg != "**") {
                throw root.CliError.new(root.ErrorCode.InvalidPolicy, `"**" must be a whole segment in pattern "${raw}"`);
            }
        }
        let effective = if (is_dir) {
            segments.concat(["**"])
        } else {
            segments
        };
        PathPattern { raw: raw, anchored: anchored, segments: effective }
    }

    function matches(self, path: RepoPath) -> bool {
        if (self.anchored) {
            PathPattern.segments_match(self.segments, 0, path.segments(), 0)
        } else {
            PathPattern.any_suffix_matches(self.segments, path.segments(), 0)
        }
    }

    function matches_change(self, change: root.FileChange) -> bool {
        if (self.matches(RepoPath { raw: change.path })) {
            return true;
        }
        match (change.old_path) {
            null => false,
            let old: string => self.matches(RepoPath { raw: old }),
        }
    }

    function segment_chars_match(pattern: string[], pi: int, text: string[], ti: int) -> bool {
        match (pattern.at(pi)) {
            null => ti >= text.length(),
            "*" => {
                PathPattern.segment_chars_match(pattern, pi + 1, text, ti)
                    || (
                        ti < text.length()
                            && PathPattern.segment_chars_match(pattern, pi, text, ti + 1)
                    )
            },
            "?" => {
                ti < text.length() && PathPattern.segment_chars_match(pattern, pi + 1, text, ti + 1)
            },
            let pc: string => match (text.at(ti)) {
                null => false,
                let tc: string => {
                    pc == tc && PathPattern.segment_chars_match(pattern, pi + 1, text, ti + 1)
                },
            },
        }
    }

    function segments_match(pattern: string[], pi: int, path: string[], si: int) -> bool {
        match (pattern.at(pi)) {
            null => si >= path.length(),
            "**" => {
                pi + 1 >= pattern.length()
                    || PathPattern.segments_match(pattern, pi + 1, path, si)
                    || (si < path.length() && PathPattern.segments_match(pattern, pi, path, si + 1))
            },
            let seg: string => match (path.at(si)) {
                null => false,
                let candidate: string => {
                    PathPattern.segment_chars_match(seg.chars(), 0, candidate.chars(), 0)
                        && PathPattern.segments_match(pattern, pi + 1, path, si + 1)
                },
            },
        }
    }

    function any_suffix_matches(pattern: string[], parts: string[], start: int) -> bool {
        start <= parts.length()
            && (
                PathPattern.segments_match(pattern, 0, parts, start)
                    || PathPattern.any_suffix_matches(pattern, parts, start + 1)
            )
    }
}

test "anchored directory pattern" {
    let p = PathPattern.compile("/stdlib/");
    assert.is_true(p.matches(RepoPath { raw: "stdlib/env.baml" }));
    assert.is_true(p.matches(RepoPath { raw: "stdlib/a/b.baml" }));
    assert.equal(p.matches(RepoPath { raw: "src/stdlib/env.baml" }), false)
}

test "unanchored and globstar patterns" {
    let p = PathPattern.compile("/src/api/**");
    assert.is_true(p.matches(RepoPath { raw: "src/api/handler.ts" }));
    assert.equal(p.matches(RepoPath { raw: "src/web/handler.ts" }), false);
    let any = PathPattern.compile("*");
    assert.is_true(any.matches(RepoPath { raw: "deeply/nested/file.ts" }));
    let ts = PathPattern.compile("*.ts");
    assert.is_true(ts.matches(RepoPath { raw: "app/config.ts" }));
    assert.equal(ts.matches(RepoPath { raw: "app/config.js" }), false)
}

test "question mark and segment star" {
    let p = PathPattern.compile("/src/file?.ts");
    assert.is_true(p.matches(RepoPath { raw: "src/file1.ts" }));
    assert.equal(p.matches(RepoPath { raw: "src/file12.ts" }), false)
}
