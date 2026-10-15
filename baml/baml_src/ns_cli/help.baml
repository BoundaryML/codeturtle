// Offline help text: the full `codeturtle help` reference.
class Help {
    function text() -> string {
        `
            CodeTurtle - who must review which changed files, and why.

            Commands:
              codeturtle check [--backend URL] [--base REF] [--report-out PATH]
              codeturtle lint
              codeturtle help
              codeturtle version

            check options (exactly these three):
              --backend URL      Authenticate through Actions OIDC, evaluate
                                 backend-issued PR inputs, and upload the report.
                                 URL must be an HTTPS origin without credentials.
              --base REF         Comparison base for a local preview. Head is HEAD.
                                 Rejected together with --backend.
              --report-out PATH  Also save the exact JSON report to PATH (atomic).
                                 Never enables or disables upload.

            Without --backend, check is a local preview and makes no backend calls.
            Policy and conditions come from the base snapshot, so a change cannot
            weaken its own rules. Dirty worktree changes are excluded.
            Exit 0 means requirements were evaluated (and uploaded, when hosted).
            It never means humans approved.

            Policy: root CODETURTLE.md, exactly one fenced codeturtle block.
            An empty block is valid and requires no review.

              /stdlib/ @alice @bob # codeturtle: all
              * @example/security # codeturtle: when=checks.adds_environment_access
              /src/api/** @example/api # codeturtle: when=checks.undocumented_api_change

            Path grammar: case-sensitive, / separated. Leading / anchors at the
            repository root; unanchored patterns match beneath any directory.
            * matches within a segment, ? matches one character, a whole **
            segment spans directories, trailing / matches all descendants, and
            bare * matches every file. All matching rules accumulate.
            Owners are @user or @org/team. Default threshold is any;
            # codeturtle: all requires every listed owner principal.

            Condition contracts (when=checks.name):
              FileChange    invoked once per matching file -> bool or Match
              FileChange[]  invoked once with matching files -> bool or Match[]
              PullRequest   invoked once with PR context   -> bool or Match[]
            Match carries path, verdict (applies | does_not_apply | uncertain),
            reason, and optional evidence. Uncertain requests human review.
            Detailed results may select a subset of the rule scope, never escape it.
            Registered checks:
              checks.adds_environment_access  (FileChange)
              checks.undocumented_api_change  (FileChange)
              checks.touches_binary_files     (FileChange[])
              checks.title_mentions_breaking  (PullRequest)

            FileChange: path, old_path, status, before/after blob ids, nullable
            before_text/after_text, added_text, removed_text, patch, hunks,
            is_binary, content_available, is_submodule, is_symlink.
            PullRequest: repository, number, title, body, labels, author_id,
            head, base, merge_base, changes.

            lint validates working-tree policy syntax, owners, and condition
            names/contracts. It invokes no predicates and makes no network calls.

            Exit codes:
              0 success - 1 invalid policy or failed evaluation -
              2 usage, environment, git input, or report-write failure -
              3 authentication, registration, or upload failure -
              4 superseded attempt or closed PR - 130 interrupted
        `
    }
}
