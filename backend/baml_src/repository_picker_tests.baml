class PickerTestTransport {
    calls: string[],
    implements Transport {
        function send(self, method: string, url: string, token: string, payload: json) -> json {
            assert.equal(method, "GET");
            assert.equal(token, "user-token");
            self.calls.push(url);
            if (url == "https://api.github.com/user/installations?per_page=100&page=1") {
                return {"installations": [
                    {"id": 9, "app_id": 7, "suspended_at": null},
                    {"id": 10, "app_id": 8, "suspended_at": null},
                    {"id": 11, "app_id": 7, "suspended_at": "2026-01-01"}
                ]};
            }
            if (url == "https://api.github.com/user/installations/9/repositories?per_page=100&page=1") {
                let repos: json[] = [];
                let i = 0;
                while (i < 100) {
                    repos.push({"id": i, "full_name": "owner/ignored", "permissions": {"admin": false}});
                    i += 1;
                }
                return {"repositories": repos};
            }
            assert.equal(url, "https://api.github.com/user/installations/9/repositories?per_page=100&page=2");
            {"repositories": [
                {"id": 42, "full_name": "owner/allowed", "permissions": {"admin": true}, "default_branch": "main"},
                {"id": 43, "full_name": "owner/archived", "permissions": {"admin": true}, "archived": true},
                {"id": 44, "full_name": "owner/missing-permissions"}
            ]}
        }
    }
}

test "Repository discovery paginates and excludes other apps suspended installations and non-admin repos" {
    let transport = PickerTestTransport {calls: []};
    assert.equal(discover_repositories(transport, "user-token", "7"), [
        {"id": "42", "name": "owner/allowed", "installation_id": "9", "default_branch": "main"}
    ]);
    assert.equal(transport.calls.length(), 3)
}
