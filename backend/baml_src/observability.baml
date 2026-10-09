// Explicit spans for service boundaries. Never capture request bodies, cookies,
// provider credentials, database payloads, or returned session tokens here.
function service_trace(stage: string) -> trace.Options {
    trace.span(inputs = false, output = false, error = false).context(
        metadata = { "service": "codeturtle", "stage": stage },
    )
}

// A credential-free probe for checking recording + querying on the host.
function studio_probe() -> string {
    studio_probe_step($trace = service_trace("probe"))
}

function studio_probe_step() -> string {
    "codeturtle tracing ready"
}
