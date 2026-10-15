function main() -> null {
    let code = root.cli.Cli.run(baml.sys.argv()) catch (e) {
        CliError => {
            baml.io.eprintln(`CodeTurtle: ${e.message} [${e.code}]`);
            e.code.exit_code()
        },
    };
    baml.sys.exit(code)
}
