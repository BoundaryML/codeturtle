// Structured git access. `Git.run` is the only process execution in
// this file; every operation is a typed verb on `Git` returning domain
// values (Revision, TreeMode, NameStatus, FileChange). Argv arrays
// only, never a shell, so paths with spaces or newlines survive intact.

class Revision {
    sha: string,

    function short(self) -> string {
        root.lib.text.Text.short_rev(self.sha)
    }
}

implement baml.ToString for Revision {
    function to_string(self) -> string {
        self.sha
    }
}

enum TreeMode {
    Regular,
    Executable,
    Symlink,
    Submodule,
    Tree,
    Missing,
}

class NameStatus {
    status: root.ChangeStatus,
    path: string,
    old_path: string?,
}

class Patch {
    raw: string,

    function hunks(self) -> root.Hunk[] {
        let hunks: root.Hunk[] = [];
        let current_lines: string[] = [];
        let current_header = "";
        for (let line in self.raw.lines()) {
            if (line.starts_with("@@")) {
                if (!current_header.is_empty()) {
                    hunks.push(root.Hunk { header: current_header, lines: current_lines });
                }
                current_header = line;
                current_lines = [];
            } else if (!current_header.is_empty()) {
                current_lines.push(line);
            }
        }
        if (!current_header.is_empty()) {
            hunks.push(root.Hunk { header: current_header, lines: current_lines });
        }
        hunks
    }

    function added_text(self) -> string {
        self.raw.lines()
            .filter((line: string) -> bool {
                line.starts_with("+") && !line.starts_with("+++")
            })
            .map((line: string) -> string {
                line.slice(1, line.length())
            })
            .join("\n")
    }

    function removed_text(self) -> string {
        self.raw.lines()
            .filter((line: string) -> bool {
                line.starts_with("-") && !line.starts_with("---")
            })
            .map((line: string) -> string {
                line.slice(1, line.length())
            })
            .join("\n")
    }
}

class Git {
    cwd: string?,

    function here() -> Git {
        Git { cwd: null }
    }

    function in_directory(path: string) -> Git {
        Git { cwd: path }
    }

    function run(self, args: string[]) -> baml.sys.ShellOutput throws root.CliError {
        baml.sys.exec(
            "git",
            args,
            baml.sys.ProcessOptions {
                cwd: self.cwd,
                env: null,
                timeout_ms: root.lib.limits.Limits.git_timeout_ms(),
                stdin: null,
                stderr: null,
            },
        ) catch (e) {
            baml.errors.Io => {
                throw root.CliError.new(root.ErrorCode.RepositoryUnavailable, `git failed to run: ${e.message}`)
            },
            baml.errors.Timeout => {
                throw root.CliError.new(root.ErrorCode.InputUnavailable, "git timed out")
            },
        }
    }

    function succeeds(self, args: string[]) -> bool throws root.CliError {
        self.run(args).ok()
    }

    function text(
        self,
        args: string[],
        code: root.ErrorCode,
        what: string,
    ) -> string throws root.CliError {
        let out = self.run(args);
        if (!out.ok()) {
            throw root.CliError.new(code, `${what}: ${Git.stderr_of(out)}`);
        }
        match (root.lib.text.Text.decode_utf8(out.stdout)) {
            null => {
                throw root.CliError.new(root.ErrorCode.UnsupportedPathEncoding, `${what}: output is not valid UTF-8`)
            },
            let s: string => s,
        }
    }

    function text_or_null(self, args: string[]) -> string? throws root.CliError {
        let out = self.run(args);
        if (!out.ok()) {
            return null;
        }
        match (root.lib.text.Text.decode_utf8(out.stdout)) {
            null => null,
            let s: string => s.trim(),
        }
    }

    function bytes_or_null(self, args: string[]) -> uint8array? throws root.CliError {
        let out = self.run(args);
        if (out.ok()) {
            out.stdout
        } else {
            null
        }
    }

    function stderr_of(out: baml.sys.ShellOutput) -> string {
        match (root.lib.text.Text.decode_utf8(out.stderr)) {
            null => "",
            let s: string => s.trim(),
        }
    }

    function require_repository(self) -> null throws root.CliError {
        if (!self.succeeds(["rev-parse", "--git-dir"])) {
            throw root.CliError.new(root.ErrorCode.RepositoryUnavailable, "current directory is not a git repository");
        }
        null
    }

    function resolve_commit(self, rev: string) -> Revision throws root.CliError {
        Revision {
            sha: self
                .text(
                    ["rev-parse", "--verify", "--quiet", `${rev}^{commit}`],
                    root.ErrorCode.InvalidRevision,
                    `cannot resolve ${rev}`,
                )
                .trim(),
        }
    }

    function try_resolve_commit(self, rev: string) -> Revision? throws root.CliError {
        match (self.text_or_null(["rev-parse", "--verify", "--quiet", `${rev}^{commit}`])) {
            null => null,
            let sha: string => Revision { sha: sha },
        }
    }

    function head(self) -> Revision throws root.CliError {
        self.resolve_commit("HEAD")
    }

    function fetch_commit(self, sha: string) -> bool throws root.CliError {
        self.succeeds(["fetch", "--no-tags", "origin", sha])
    }

    function default_base_ref(self) -> string? throws root.CliError {
        match (self.text_or_null(["rev-parse", "--abbrev-ref", "@{upstream}"])) {
            null => {
                match (self.text_or_null(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])) {
                    null => null,
                    let s: string => s.replace("refs/remotes/", ""),
                }
            },
            let upstream: string => upstream,
        }
    }

    function merge_bases(self, base: Revision, head: Revision) -> Revision[] throws root.CliError {
        let out = self.run(["merge-base", "--all", base.sha, head.sha]);
        if (!out.ok()) {
            throw root.CliError.new(root.ErrorCode.InputUnavailable, `cannot compute merge-base: ${Git.stderr_of(out)}`);
        }
        match (root.lib.text.Text.decode_utf8(out.stdout)) {
            null => {
                throw root.CliError.new(root.ErrorCode.InputUnavailable, "merge-base output is not valid UTF-8")
            },
            let s: string => {
                s.lines()
                    .filter((l: string) -> bool {
                        !l.trim().is_empty()
                    })
                    .map((l: string) -> Revision {
                        Revision { sha: l.trim() }
                    })
            },
        }
    }

    function merge_base(self, base: Revision, head: Revision) -> Revision throws root.CliError {
        let bases = self.merge_bases(base, head);
        match (bases.length()) {
            1 => bases[0],
            0 => {
                throw root.CliError.new(root.ErrorCode.InputUnavailable, "no merge-base between base and HEAD")
            },
            _ => {
                throw root.CliError.new(root.ErrorCode.AmbiguousMergeBase, "multiple merge-bases; refusing to choose one")
            },
        }
    }

    function is_dirty(self) -> bool throws root.CliError {
        let out = self.run(["status", "--porcelain"]);
        out.ok() && out.stdout.length() > 0
    }

    function show_file(self, rev: Revision, path: string) -> uint8array? throws root.CliError {
        self.bytes_or_null(["show", `${rev.sha}:${path}`])
    }

    function blob_id(self, rev: Revision, path: string) -> string? throws root.CliError {
        self.text_or_null(["rev-parse", "--quiet", "--verify", `${rev.sha}:${path}`])
    }

    function mode_at(self, rev: Revision, path: string) -> TreeMode throws root.CliError {
        match (self.text_or_null(["ls-tree", rev.sha, "--", path])) {
            null => TreeMode.Missing,
            let s: string => match (s.split(" ").at(0)) {
                null => TreeMode.Missing,
                "100644" => TreeMode.Regular,
                "100755" => TreeMode.Executable,
                "120000" => TreeMode.Symlink,
                "160000" => TreeMode.Submodule,
                "040000" => TreeMode.Tree,
                _ => TreeMode.Missing,
            },
        }
    }

    function parse_status_code(code: string) -> root.ChangeStatus throws root.CliError {
        match (code) {
            "A" => "added",
            "M" => "modified",
            "D" => "deleted",
            "T" => "typechanged",
            _ => {
                if (code.starts_with("R")) {
                    "renamed"
                } else {
                    throw root.CliError.new(root.ErrorCode.InputUnavailable, `unsupported git status "${code}"`)
                }
            },
        }
    }

    function nul() -> string throws root.CliError {
        string.from_code_points([0]) catch (e) {
            baml.errors.InvalidArgument => {
                throw root.CliError.new(root.ErrorCode.InputUnavailable, "cannot build NUL separator")
            },
        }
    }

    function name_status(
        self,
        merge_base: Revision,
        head: Revision,
    ) -> NameStatus[] throws root.CliError {
        let out = self.run(["diff", "--name-status", "-z", "-M", merge_base.sha, head.sha]);
        if (!out.ok()) {
            throw root.CliError.new(
                root.ErrorCode.InputUnavailable,
                `cannot diff ${merge_base.short()}..${head.short()}: ${Git.stderr_of(out)}`,
            );
        }
        let text = match (root.lib.text.Text.decode_utf8(out.stdout)) {
            null => {
                throw root.CliError.new(root.ErrorCode.UnsupportedPathEncoding, "a changed path is not valid UTF-8")
            },
            let s: string => s,
        };
        let tokens = text.split(Git.nul()).filter((t: string) -> bool {
            !t.is_empty()
        });
        let entries: NameStatus[] = [];
        let i = 0;
        while (i < tokens.length()) {
            let status = Git.parse_status_code(tokens[i]);
            match (status) {
                "renamed" => {
                    if (i + 2 >= tokens.length()) {
                        throw root.CliError.new(root.ErrorCode.InputUnavailable, "malformed rename in git diff output");
                    }
                    entries.push(
                        NameStatus { status: status, path: tokens[i + 2], old_path: tokens[i + 1] },
                    );
                    i = i + 3;
                },
                _ => {
                    if (i + 1 >= tokens.length()) {
                        throw root.CliError.new(root.ErrorCode.InputUnavailable, "malformed git diff output");
                    }
                    entries.push(NameStatus { status: status, path: tokens[i + 1], old_path: null });
                    i = i + 2;
                },
            };
        }
        if (entries.length() > root.lib.limits.Limits.max_changed_files()) {
            throw root.CliError.new(root.ErrorCode.InputLimitExceeded, `changed file count exceeds ${root.lib.limits.Limits.max_changed_files()}`);
        }
        entries
    }

    function diff_patch(
        self,
        merge_base: Revision,
        head: Revision,
        entry: NameStatus,
    ) -> Patch throws root.CliError {
        let args = ["diff", "--no-color", merge_base.sha, head.sha, "--"];
        match (entry.old_path) {
            null => args.push(entry.path),
            let old: string => {
                args.push(old);
                args.push(entry.path);
            },
        };
        let out = self.run(args);
        if (!out.ok()) {
            throw root.CliError.new(root.ErrorCode.InputUnavailable, `cannot produce patch for ${entry.path}: ${Git.stderr_of(out)}`);
        }
        Patch { raw: root.lib.text.Text.decode_utf8(out.stdout) ?? "" }
    }

    function text_side(data: uint8array?, path: string) -> string? throws root.CliError {
        match (data) {
            null => null,
            let bytes: uint8array => {
                if (bytes.length() > root.lib.limits.Limits.max_file_text_bytes()) {
                    throw root.CliError.new(root.ErrorCode.InputLimitExceeded, `${path} exceeds the text input limit`);
                }
                root.lib.text.Text.decode_utf8(bytes)
            },
        }
    }

    function build_change(
        self,
        entry: NameStatus,
        merge_base: Revision,
        head: Revision,
    ) -> root.FileChange throws root.CliError {
        let before_path = entry.old_path ?? entry.path;
        let before_data = match (entry.status) {
            "added" => null,
            _ => self.show_file(merge_base, before_path),
        };
        let after_data = match (entry.status) {
            "deleted" => null,
            _ => self.show_file(head, entry.path),
        };
        let before_mode = self.mode_at(merge_base, before_path);
        let after_mode = self.mode_at(head, entry.path);
        let is_submodule = before_mode == TreeMode.Submodule || after_mode == TreeMode.Submodule;
        let is_symlink = before_mode == TreeMode.Symlink || after_mode == TreeMode.Symlink;
        let patch = self.diff_patch(merge_base, head, entry);
        let before_text = if (is_submodule) {
            null
        } else {
            Git.text_side(before_data, entry.path)
        };
        let after_text = if (is_submodule) {
            null
        } else {
            Git.text_side(after_data, entry.path)
        };
        let has_data = before_data != null || after_data != null;
        let decodable = (before_data == null || before_text != null) && (after_data == null || after_text != null);
        root.FileChange {
            path: entry.path,
            old_path: entry.old_path,
            status: entry.status,
            before_blob: self.blob_id(merge_base, before_path),
            after_blob: self.blob_id(head, entry.path),
            before_text: before_text,
            after_text: after_text,
            added_text: patch.added_text(),
            removed_text: patch.removed_text(),
            patch: patch.raw,
            hunks: patch.hunks(),
            is_binary: !is_submodule && has_data && !decodable,
            content_available: has_data,
            is_submodule: is_submodule,
            is_symlink: is_symlink,
        }
    }

    function inventory(
        self,
        merge_base: Revision,
        head: Revision,
    ) -> root.FileChange[] throws root.CliError {
        let git = self;
        let changes = self.name_status(merge_base, head).map((entry: NameStatus) -> root.FileChange {
            git.build_change(entry, merge_base, head)
        });
        changes.sort_by((a: root.FileChange, b: root.FileChange) -> baml.ops.Ordering {
            a.path.cmp(b.path)
        });
        changes
    }

    function read_policy_at(self, rev: Revision) -> string throws root.CliError {
        match (self.show_file(rev, policy_source_name())) {
            null => {
                throw root.CliError.new(root.ErrorCode.PolicyMissing, `${policy_source_name()} not found at ${rev.short()}`)
            },
            let data: uint8array => match (root.lib.text.Text.decode_utf8(data)) {
                null => {
                    throw root.CliError.new(root.ErrorCode.InvalidPolicy, `${policy_source_name()} is not valid UTF-8`)
                },
                let text: string => text,
            },
        }
    }
}

function change_digest(change: root.FileChange) -> string {
    root.lib.digest.Digest.sha256_hex(
        `${change.status}\n${change.old_path ?? ""}\n${change.path}\n${change.patch}`,
    )
}

test "patch splits added and removed text" {
    let p = Patch { raw: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new line\n" };
    assert.equal(p.added_text(), "new line");
    assert.equal(p.removed_text(), "old");
    assert.equal(p.hunks().length(), 1)
}
