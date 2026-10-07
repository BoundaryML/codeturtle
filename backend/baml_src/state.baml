interface RunStore {
    function rpc(self, name: string, payload: json) -> json throws unknown;
    function enrollment(self, repository_id: string) -> Enrollment throws unknown {
        baml.json.to<Enrollment>(self.rpc("enrollment", { "repository_id": repository_id }))
    }
    function register(
        self,
        run: AuthorizedRun,
        token_hash: string,
        expires_at: int,
    ) -> StoredRun throws unknown {
        baml.json.to<StoredRun>(
            self.rpc(
                "register",
                {
                    "authorized": baml.json.from(run),
                    "token_hash": token_hash,
                    "expires_at": expires_at,
                },
            ),
        )
    }
    function lookup(self, id: string, token_hash: string) -> StoredRun throws unknown {
        baml.json.to<StoredRun>(self.rpc("lookup", { "id": id, "token_hash": token_hash }))
    }
    function accept(
        self,
        id: string,
        token_hash: string,
        digest: string,
        envelope: ReportEnvelope,
    ) -> StoredRun throws unknown {
        baml.json.to<StoredRun>(
            self.rpc(
                "accept",
                {
                    "id": id,
                    "token_hash": token_hash,
                    "digest": digest,
                    "envelope": baml.json.from(envelope),
                },
            ),
        )
    }
}

class SupabaseStore {
    url: string,
    key: string,
    implements RunStore {
        function rpc(self, name: string, payload: json) -> json {
            let r = baml.http.send(
                baml.http.Request.from_url(self.url + "/rest/v1/rpc/ct_" + name)
                    .set_method("POST")
                    .set_headers(
                        {
                            "apikey": self.key,
                            "authorization": "Bearer " + self.key,
                            "content-type": "application/json",
                        },
                    )
                    .set_body(baml.json.stringify({ "p": payload }))
                    .set_timeout(baml.time.Duration.from_seconds(15)),
            );
            require(r.status_code >= 200 && r.status_code < 300, 503, "database_unavailable");
            let result = baml.json.parse(r.text());
            if (field(result, "error") != null) {
                throw ApiError {status: num(result, "status"), code: str(result, "error")};
            }
            result
        }
    }
}

class SecretBox {
    key: uint8array,
    function seal(self, value: string, scope: string) -> string {
        let nonce = baml.random.SystemRandom.get().random(12);
        nonce.to_hex()
            + ":"
            + baml.crypto.Aes256GcmSiv.new(self.key)
                .encrypt(nonce, value.to_utf8(), scope.to_utf8())
                .to_hex()
    }
    function open(self, value: string, scope: string) -> string {
        let parts = value.split(":");
        require(parts.length() == 2, 503, "invalid_encrypted_secret");
        baml.crypto.Aes256GcmSiv.new(self.key)
            .decrypt(uint8array.from_hex(parts[0]), uint8array.from_hex(parts[1]), scope.to_utf8())
            .to_string()
    }
}

test "Encrypted secrets are bound to workspace and authenticate ciphertext" {
    let box = SecretBox { key: uint8array.zeroes(32) };
    let sealed = box.seal("test-token", "slack:T1");
    assert.equal(box.open(sealed, "slack:T1"), "test-token");
    let rejected = box.open(sealed, "slack:T2") catch_all (_) {
        _ => "rejected"
    };
    assert.equal(rejected, "rejected")
}
