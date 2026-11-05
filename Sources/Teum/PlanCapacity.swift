import Foundation
import QuotaCore

/// One %p of a weekly window is a different amount of work on each plan.
/// Teum compares plans in weighted tokens, a fixed price-like weighting that
/// does not depend on any one model's price list.
enum WorkTokens {
    static let formula = "새 입력 + 출력×4 + 캐시 읽기×0.1 + 캐시 쓰기×1.25"
    static func weighted(fresh:Double,output:Double,cacheRead:Double,cacheWrite:Double)->Double {
        fresh+4*output+0.1*cacheRead+1.25*cacheWrite
    }
}

struct CapacitySample:Codable,Equatable {
    var t:Double
    var used:Double
    var reset:Double?
}

struct CapacityEstimate:Codable,Equatable {
    /// Weighted tokens per 1%p of the weekly window; nil when not measurable.
    var tokensPerPoint:Double?
    var points:Double = 0
    var windows:Int = 0
    var method:String
    var note:String?
    var measuredAt:Date
    /// Fewer than 10 observed points: usable, but say so.
    var lowConfidence:Bool {tokensPerPoint != nil && points<10}
    var summary:String {
        if let tokensPerPoint {return "1%p ≈ \(TokenText.count(Int(tokensPerPoint))) · \(windows)주기 \(Int(points.rounded()))%p 기준"+(lowConfidence ? " · 표본 적음" : "")}
        return note ?? "추정 없음"
    }
}

/// Estimates and the weekly samples they are measured from.
struct CapacityBook:Codable,Equatable {
    var version = 1
    var estimates:[String:CapacityEstimate] = [:]
    var samples:[String:[CapacitySample]] = [:]
    var estimatedAt:Date?
    static let keep:TimeInterval = 45*86400
    /// Keeps a sample when the weekly figure moves by 0.5%p or a new window
    /// starts, so fractional providers do not add one per refresh.
    @discardableResult mutating func record(id:String,used:Double,reset:Date?,at:Date)->Bool {
        guard used.isFinite,(0...100).contains(used) else{return false}
        var list = samples[id] ?? []
        let r = reset?.timeIntervalSince1970
        if let last = list.last {
            guard at.timeIntervalSince1970>last.t else{return false}
            let sameWindow = CapacityEstimator.sameWindow(last.reset,r)
            if sameWindow && abs(last.used-used)<0.5 {return false}
        }
        list.append(CapacitySample(t:at.timeIntervalSince1970,used:used,reset:r))
        let floor = at.timeIntervalSince1970-Self.keep
        samples[id] = list.filter{$0.t>=floor}
        return true
    }
}

enum CapacityEstimator {
    static let horizon:TimeInterval = 45*86400
    static func sameWindow(_ a:Double?,_ b:Double?)->Bool {
        guard let a,let b else{return a == nil && b == nil}
        return abs(a-b)<60
    }

    /// Codex writes the turn's tokens and the account's limits into every
    /// token_count event, so one weekly window yields tokens per point directly.
    struct Codex {
        struct Window {var lo = Double.infinity;var hi = -Double.infinity;var weighted = 0.0;var events = 0}
        var windows:[Int:Window] = [:]
        private var seen = Set<String>()
        mutating func add(_ line:Data) {
            guard let row = try? JSONSerialization.jsonObject(with:line) as? [String:Any] else{return}
            let payload = row["payload"] as? [String:Any] ?? row
            guard payload["type"] as? String == "token_count",let info = payload["info"] as? [String:Any],
                  let last = info["last_token_usage"] as? [String:Any],let limits = payload["rate_limits"] as? [String:Any] else{return}
            // Resumed and forked sessions replay earlier events into new files.
            let total = (info["total_token_usage"] as? [String:Any])?["total_tokens"] as? Double ?? -1
            guard seen.insert("\(row["timestamp"] as? String ?? "")|\(total)|\(last["total_tokens"] as? Double ?? -1)").inserted else{return}
            let input = last["input_tokens"] as? Double ?? 0,cached = last["cached_input_tokens"] as? Double ?? 0
            let weighted = WorkTokens.weighted(fresh:max(0,input-cached),output:last["output_tokens"] as? Double ?? 0,cacheRead:cached,cacheWrite:last["cache_write_input_tokens"] as? Double ?? 0)
            for slot in ["primary","secondary"] {
                guard let w = limits[slot] as? [String:Any],w["window_minutes"] as? Double == 10080,
                      let used = w["used_percent"] as? Double,let reset = w["resets_at"] as? Double else{continue}
                let key = Int((reset/3600).rounded())
                var bucket = windows[key] ?? Window()
                bucket.lo = min(bucket.lo,used);bucket.hi = max(bucket.hi,used)
                bucket.weighted += weighted;bucket.events += 1
                windows[key] = bucket
            }
        }
        mutating func scan(file:URL) {
            guard let data = try? Data(contentsOf:file,options:.alwaysMapped) else{return}
            let needle = Array("\"token_count\"".utf8)
            data.withUnsafeBytes {(raw:UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else{return}
                var offset = 0
                while offset<raw.count,let hit = memmem(base+offset,raw.count-offset,needle,needle.count) {
                    let at = base.distance(to:UnsafeRawPointer(hit))
                    var start = at
                    while start>0,raw[start-1] != 0x0A {start -= 1}
                    let end = memchr(base+at,0x0A,raw.count-at).map{base.distance(to:UnsafeRawPointer($0))} ?? raw.count
                    add(Data(bytes:base+start,count:end-start))
                    offset = end+1
                }
            }
        }
        func estimate(now:Date)->CapacityEstimate {
            let usable = windows.values.filter{$0.events>=30 && $0.hi-$0.lo>=5}
            let points = usable.reduce(0){$0+($1.hi-$1.lo)}
            let tokens = usable.reduce(0){$0+$1.weighted}
            if points>=3 {return CapacityEstimate(tokensPerPoint:tokens/points,points:points,windows:usable.count,method:"codex-log",measuredAt:now)}
            return CapacityEstimate(points:points,windows:usable.count,method:"codex-log",note:windows.isEmpty ? "최근 45일 로그 없음" : "표본 부족",measuredAt:now)
        }
    }

    static func codex(sessions:URL,now:Date)->CapacityEstimate {
        var reader = Codex()
        let keys:[URLResourceKey] = [.contentModificationDateKey,.isRegularFileKey]
        let since = now.addingTimeInterval(-horizon)
        if let files = FileManager.default.enumerator(at:sessions,includingPropertiesForKeys:keys) {
            for case let file as URL in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys:Set(keys)),values.isRegularFile == true,(values.contentModificationDate ?? .distantPast)>=since else{continue}
                reader.scan(file:file)
            }
        }
        return reader.estimate(now:now)
    }

    /// Claude Code logs carry no limits, so Teum's own weekly samples are set
    /// against Claude Code tokens in the same hours. Hourly totals are raw;
    /// each day's model mix converts them to weighted tokens.
    static func claude(samples:[CapacitySample],cache:TokenHistoryCache?,now:Date)->CapacityEstimate {
        guard let cache,let covered = cache.projects.lastScan?.timeIntervalSince1970 else {
            return CapacityEstimate(method:"teum-ledger",note:"토큰 기록 없음",measuredAt:now)
        }
        let source = CostSource.claudeCode.rawValue
        var hourly:[(start:Double,tokens:Double)] = []
        for (day,projects) in cache.projects.days {
            guard let start = UsageArchive.date(forKey:day)?.timeIntervalSince1970 else{continue}
            let entries = (cache.archive.days[day]?[source] ?? [:]).values
            let raw = entries.reduce(0.0){$0+Double($1.allTokens)}
            let factor = raw>0 ? entries.reduce(0.0){$0+WorkTokens.weighted(fresh:Double($1.input),output:Double($1.output),cacheRead:Double($1.cacheRead),cacheWrite:Double($1.cacheWrite))}/raw : 0
            var hours = Array(repeating:0.0,count:24)
            for sources in projects.values {
                for bucket in (sources[source] ?? [:]).values {
                    for (h,n) in bucket.hours.prefix(24).enumerated() {hours[h] += Double(n)}
                }
            }
            for (h,n) in hours.enumerated() where n>0 {hourly.append((start+Double(h)*3600,n*factor))}
        }
        var points = 0.0,tokens = 0.0,windows = Set<Int>()
        for (a,b) in zip(samples,samples.dropFirst()) {
            // Only spans the token history has read, inside one weekly window.
            guard b.t<=covered,b.used>a.used,sameWindow(a.reset,b.reset) else{continue}
            points += b.used-a.used
            for hour in hourly where hour.start<b.t && hour.start+3600>a.t {
                tokens += hour.tokens*(min(b.t,hour.start+3600)-max(a.t,hour.start))/3600
            }
            windows.insert(Int(((b.reset ?? 0)/3600).rounded()))
        }
        // Whole-percent readings make a few points coarse; still better than none.
        if points>=3,tokens>0 {return CapacityEstimate(tokensPerPoint:tokens/points,points:points,windows:windows.count,method:"teum-ledger",measuredAt:now)}
        return CapacityEstimate(points:points,windows:windows.count,method:"teum-ledger",note:"표본 부족 \(Int(points.rounded()))%p",measuredAt:now)
    }

    static func estimate(streams:[Stream],samples:[String:[CapacitySample]],tokenCache:TokenHistoryCache?,home:URL,now:Date)->[String:CapacityEstimate] {
        var result:[String:CapacityEstimate] = [:]
        for stream in streams {
            switch stream.source {
            case "codex":
                let root = home.appendingPathComponent(stream.profile.isEmpty ? ".codex" : ".codex-\(stream.profile)")
                result[stream.id] = codex(sessions:root.appendingPathComponent("sessions"),now:now)
            case "claude":
                result[stream.id] = claude(samples:samples[stream.id] ?? [],cache:tokenCache,now:now)
            default:
                result[stream.id] = CapacityEstimate(method:"none",note:"Teum이 읽는 토큰 기록 없음",measuredAt:now)
            }
        }
        return result
    }
}
