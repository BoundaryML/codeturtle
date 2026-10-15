class Digest {
    function sha256_hex(text: string) -> string {
        let h = baml.crypto.Sha256.new();
        h.update(text.to_utf8());
        h.finish().to_hex()
    }

    function sha256_hex_bytes(data: uint8array) -> string {
        let h = baml.crypto.Sha256.new();
        h.update(data);
        h.finish().to_hex()
    }
}

test "digest known vector" {
    assert.equal(
        Digest.sha256_hex("hello"),
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
    )
}
