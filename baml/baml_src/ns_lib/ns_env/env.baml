// Environment access with stdlib failures already tamed.

function env_or_null(name: string) -> string? {
    baml.env.get(name) catch (e) {
        baml.errors.Io => null,
        baml.errors.ParseError => null,
    }
}

function env_required(name: string, code: root.ErrorCode) -> string throws root.CliError {
    match (env_or_null(name)) {
        null => throw root.CliError.new(code, `missing environment variable ${name}`),
        let value: string => value,
    }
}
