// Process-local byte-bounded LRU. A one-slot gate protects metadata; loaders use
// a separate four-slot limit so independent content downloads can run concurrently.
class CacheEntry { value: json, expires: int, size: int }
class BoundedCache {
    entries: map<string, CacheEntry>,
    pending: map<string, baml.future.Future<json, unknown>>,
    bytes: int,
    max_bytes: int,
    gate: baml.spawn.Limit,
    work: baml.spawn.Limit,
    generation: int,
    function get(self, key: string, ttl: int, loader: () -> json throws unknown) -> json {
        let chosen = await spawn with self.gate { self.select(key,ttl,loader) };
        await chosen
    }
    function select(self, key: string, ttl: int, loader: () -> json throws unknown) -> baml.future.Future<json, unknown> {
        if let entry: CacheEntry = self.entries.get(key) {
            if (entry.expires > now()) {
                let _ = self.entries.delete(key); self.entries[key] = entry;
                return spawn {entry.value};
            }
            self.bytes -= entry.size; let _ = self.entries.delete(key);
        }
        if let future: baml.future.Future<json, unknown> = self.pending.get(key) { return future; }
        require(self.pending.length() < 64,503,"cache_busy");
        let generation = self.generation;
        let future = spawn with self.work {
            defer { await spawn with self.gate { if (generation == self.generation) { let _ = self.pending.delete(key); } }; }
            let value = loader();
            let size = baml.json.stringify(value).to_utf8().length();
            await spawn with self.gate {
                if (generation == self.generation && size <= self.max_bytes) {
                    while (self.entries.length() >= 128 || self.bytes + size > self.max_bytes) {
                        let oldest = self.entries.keys()[0];
                        self.bytes -= self.entries[oldest].size; let _ = self.entries.delete(oldest);
                    }
                    self.entries[key] = CacheEntry {value:value, expires:now()+ttl,size:size}; self.bytes += size;
                }
            };
            value
        };
        self.pending[key] = future;
        future
    }
    function clear(self) -> void {
        await spawn with self.gate {self.entries.clear();self.pending.clear();self.bytes=0;self.generation+=1;};
    }
}
function bounded_cache(bytes: int) -> BoundedCache {
    BoundedCache {entries:{},pending:{},bytes:0,max_bytes:bytes,gate:baml.spawn.Limit.new(1),work:baml.spawn.Limit.new(4),generation:0}
}

class CacheProbe { calls: int }
test "Cache coalesces concurrent loads and respects expiry and byte bounds" {
    let cache = bounded_cache(32);
    let probe = CacheProbe {calls:0};
    let load = () -> { probe.calls += 1; baml.sys.sleep(baml.time.Duration.from_milliseconds(20)); let result: json = "value"; result };
    let a = spawn {cache.get("a",60,load)};
    let b = spawn {cache.get("a",60,load)};
    assert.equal(await a,await b);
    assert.equal(probe.calls,1);
    let _ = cache.get("b",0,load);
    let _ = cache.get("b",0,load);
    assert.equal(probe.calls,3);
    for (let key in ["c","d","e","f","g"]) {let _ = cache.get(key,60,load);}
    assert.is_true(cache.bytes <= 32);
    cache.clear();
    assert.equal(cache.bytes,0);
    assert.equal(cache.entries.length(),0)
}
