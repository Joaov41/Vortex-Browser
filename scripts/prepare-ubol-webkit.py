#!/usr/bin/env python3
"""Prepare the pinned uBOL package for Vortex's tested WebKit host.

Keep the official archive unchanged. Omit one rule whose excludedRequestDomains
are translated by WebKit into overly broad script exceptions. This omits one
filename filter; it does not add test-site filters or modify extension code.
"""
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Browser/UBOLite.safari.zip'
OUTPUT = ROOT / 'Browser/UBOLite.webkit.zip'
EXPECTED_SHA256 = '851254d65c768cf23ba4fa27e51250344cee293d7e58b9387dbc62de6bc7c306'
RULESET = 'rulesets/main/ublock-filters.json'
EXPECTED_RULE = {
    'action': {'type': 'block'},
    'condition': {'domainType': 'thirdParty',
                  'excludedRequestDomains': ['com', 'net', 'org'],
                  'resourceTypes': ['script'], 'urlFilter': '/8b3ytkn.js|'},
    'id': 5154, 'priority': 10,
}

def main():
    source_hash = hashlib.sha256(SOURCE.read_bytes()).hexdigest()
    if source_hash != EXPECTED_SHA256:
        raise SystemExit('Upstream package changed. Re-audit this compatibility omission before building.')
    with zipfile.ZipFile(SOURCE) as original:
        rules = json.loads(original.read(RULESET))
        found = [rule for rule in rules if rule.get('id') == EXPECTED_RULE['id']]
        if found != [EXPECTED_RULE]:
            raise SystemExit('Expected rule changed; refusing to alter the package.')
        amended = [rule for rule in rules if rule != EXPECTED_RULE]
        with zipfile.ZipFile(OUTPUT, 'w') as output:
            for entry in original.infolist():
                data = original.read(entry.filename)
                if entry.filename == RULESET:
                    data = (json.dumps(amended, separators=(',', ':'), ensure_ascii=False) + '\n').encode()
                output.writestr(entry, data)
    with zipfile.ZipFile(SOURCE) as original, zipfile.ZipFile(OUTPUT) as output:
        assert original.namelist() == output.namelist()
        changed = [name for name in original.namelist() if original.read(name) != output.read(name)]
        assert changed == [RULESET], changed
        assert json.loads(output.read(RULESET)) == amended
    report = {'upstreamVersion': '2026.907.2003', 'upstreamSHA256': source_hash,
              'compatibilitySHA256': hashlib.sha256(OUTPUT.read_bytes()).hexdigest(),
              'changedEntries': changed, 'omittedRule': EXPECTED_RULE,
              'rulesBefore': len(rules), 'rulesAfter': len(amended)}
    (ROOT / 'docs/ubol-webkit-package-validation.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
