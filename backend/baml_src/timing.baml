// Per-request metrics contain stage names, counts and durations only, never URLs or data.
class RequestTiming {
    gate: baml.spawn.Limit,
    durations: map<string, int>,
    counts: map<string, int>,
    function record(self, name: string, started: baml.time.Instant) -> void {
        let elapsed = baml.Int.parse(started.elapsed().to_milliseconds().to_string());
        await spawn with self.gate {
        self.durations[name] = (self.durations.get(name) ?? 0) + elapsed;
        self.counts[name] = (self.counts.get(name) ?? 0) + 1;
        };
    }
    function header(self) -> string {
        self.durations.keys().map((key) -> { key + ";dur=" + self.durations[key].to_string() + ";desc=\"" + self.counts[key].to_string() + " calls\"" }).join(", ")
    }
}
class TimedStore {
    inner: RunStore,
    timing: RequestTiming,
    implements RunStore {
        function rpc(self, name: string, payload: json) -> json {
            let start = baml.time.Instant.now();
            defer { self.timing.record("db", start); }
            self.inner.rpc(name, payload)
        }
    }
}
class TimedTransport {
    inner: Transport,
    timing: RequestTiming,
    implements Transport {
        function send(self, method: string, url: string, token: string, payload: json) -> json {
            let start = baml.time.Instant.now();
            defer { self.timing.record("provider", start); }
            self.inner.send(method, url, token, payload)
        }
    }
}
