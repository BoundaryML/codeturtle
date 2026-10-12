// Host operations are implemented by the fixed supervisor, outside agent write scope.
// Trace text and agent output are evidence, never executable commands.
function execute(operation: string) -> string {
    let result = baml.sys.exec(
        "python3",
        [baml.env.get("HEAL_HOST") ?? "heal/host.py", "operation", operation],
        baml.sys.ProcessOptions {
            cwd: null,
            env: null,
            timeout_ms: 3600000,
            stdin: null,
            stderr: baml.sys.StderrMode.Pipe,
        },
    );
    if (result.exit_code != 0) {
        throw baml.errors.Io { message: "Healing operation failed: " + operation };
    }
    result.stdout.to_string().trim()
}

function cycle() -> string {
    //# Query completed spans from local Studio
    host("scan");
    //# Spawn a read-only diagnostic agent
    let diagnosis = spawn { host("diagnose") };
    if ((await diagnosis) != "repair") {
        return "no_change";
    }
    //# Spawn a separate repair agent in an isolated release directory
    let repair = spawn { host("fix") };
    if ((await repair) != "fixed") {
        return "no_change";
    }
    //# Run the supervisor's fixed checks, never model-selected shell commands
    host("test");
    //# Request promotion; supervisor independently verifies the tested artifact
    host("promote");
    "promoted"
}

// The replacement must boot successfully before the supervisor switches versions.
function ready() -> string {
    "codeturtle-heal-ready-v1"
}

test "replacement startup contract" {
    assert.equal(ready(), "codeturtle-heal-ready-v1");
}

function main() -> string {
    cycle(
        $trace = trace.span(inputs = false, output = false, error = false).context(
            metadata = { "service": "codeturtle-heal", "stage": "cycle" },
        ),
    )
}

function host(operation: string) -> string {
    execute(
        operation,
        $trace = trace.span(inputs = false, output = false, error = false).context(
            metadata = { "service": "codeturtle-heal", "stage": operation },
        ),
    )
}
