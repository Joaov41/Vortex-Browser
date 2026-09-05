// Vortex indexed network matcher. No network access, DOM scans, or per-request native bridge.
function createVortexRuleIndex(configuration) {
    const blob = configuration.domains || '';
    const hosts = configuration.hosts || {};
    // Combine only patterns with identical conditions. This preserves exceptions/type/domain
    // semantics while avoiding a thousand separate regex evaluations for an ordinary request.
    const grouped = new Map();
    for (const rule of configuration.generic || []) {
        const key = JSON.stringify([rule.i, rule.x, rule.t, rule.n, rule.f, rule.a, rule.c]);
        if (!grouped.has(key)) grouped.set(key, []);
        grouped.get(key).push(rule);
    }
    const generic = [];
    for (const rules of grouped.values()) {
        for (let offset = 0; offset < rules.length; offset += 64) {
            const batch = rules.slice(offset, offset + 64);
            generic.push({...batch[0], p: batch.map(rule => '(?:' + rule.p + ')').join('|')});
        }
    }
    const genericSet = new WeakSet(generic);
    const genericExpressions = new WeakMap();
    const documents = configuration.documentExceptions || [];
    // Bound regex retention independently of the number of installed rules.
    const compiled = new Map();
    const decisions = new Map();
    function hostMatches(host, domain) {
        return host === domain || host.endsWith('.' + domain);
    }
    function containsDomain(host) {
        let low = 0, high = blob.length;
        while (low < high) {
            const middle = (low + high) >>> 1;
            const start = blob.lastIndexOf('\n', middle - 1) + 1;
            let end = blob.indexOf('\n', middle);
            if (end < 0) end = blob.length;
            const candidate = blob.slice(start, end);
            if (candidate === host) return true;
            if (candidate < host) low = end + 1;
            else high = start;
        }
        return false;
    }
    function expression(rule) {
        if (!rule.p) return null;
        if (genericSet.has(rule)) {
            if (!genericExpressions.has(rule)) {
                let value = null;
                try { value = new RegExp(rule.p, rule.c ? '' : 'i'); } catch (_) {}
                genericExpressions.set(rule, value);
            }
            return genericExpressions.get(rule);
        }
        const key = (rule.c ? 's:' : 'i:') + rule.p;
        if (compiled.has(key)) return compiled.get(key);
        let value = null;
        try { value = new RegExp(rule.p, rule.c ? '' : 'i'); } catch (_) {}
        if (compiled.size >= 512) compiled.delete(compiled.keys().next().value);
        compiled.set(key, value);
        return value;
    }
    function matches(rule, url, pageHost, type, thirdParty) {
        if (rule.h && !hostMatches(url.hostname, rule.h)) return false;
        if ((rule.f === 1 && !thirdParty) || (rule.f === 2 && thirdParty)) return false;
        if (rule.t && !(rule.t & type)) return false;
        if (rule.n & type) return false;
        if (rule.i.length && !rule.i.some(host => hostMatches(pageHost, host))) return false;
        if (rule.x.some(host => hostMatches(pageHost, host))) return false;
        return !rule.p || !!expression(rule)?.test(url.href);
    }
    // Return -1 for an exception, 1 for a block, 0 for no matching indexed rule.
    function decide(url, pageURL, type, thirdParty) {
        const key = pageURL.href + '\n' + type + '\n' + Number(thirdParty) + '\n' + url.href;
        if (decisions.has(key)) return decisions.get(key);
        let result = 0;
        for (const rule of documents) {
            if (matches(rule, pageURL, pageURL.hostname, type, false)) { result = -1; break; }
        }
        if (result !== -1) {
            let host = url.hostname;
            while (host) {
                if (thirdParty && containsDomain(host)) result = 1;
                const bucket = Object.prototype.hasOwnProperty.call(hosts, host) ? hosts[host] : [];
                for (const rule of bucket) {
                    if (matches(rule, url, pageURL.hostname, type, thirdParty)) {
                        if (rule.a) { result = -1; break; }
                        result = 1;
                    }
                }
                if (result === -1) break;
                const dot = host.indexOf('.');
                if (dot < 0) break;
                host = host.slice(dot + 1);
            }
            if (result !== -1) {
                for (const rule of generic) {
                    // Once blocked, only exceptions can change the decision.
                    if (result === 1 && !rule.a) continue;
                    if (matches(rule, url, pageURL.hostname, type, thirdParty)) {
                        if (rule.a) { result = -1; break; }
                        result = 1;
                    }
                }
            }
        }
        if (decisions.size >= 256) decisions.delete(decisions.keys().next().value);
        // Avoid retaining exceptionally long URLs supplied by pages.
        if (key.length <= 4096) decisions.set(key, result);
        return result;
    }
    return { decide };
}
