"""Exercise the real CLI and renderer; all credential material is synthetic."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

repo = Path.cwd()
evidence = Path(__file__).parent
results = []
transcript = []
expected_provenance = 'If this repo has `.claude/skills/starcube-pr/SKILL.md`, end the PR body with a `## Provenance` section of four bullets: `**Skills:**` names of skills whose body you loaded this run (`none recorded` if your transcript shows none), `**Worker:**` harness and model plus `Sol: reviewed` or `Sol: not run`, `**Plan:**` and `**Report:**` paths or `none`. It is informational, never a readiness gate; invent nothing and omit home paths, hosts, and secrets.'

with tempfile.TemporaryDirectory(prefix='.live-bundle-check-', dir=repo) as temporary:
    root = Path(temporary)
    home = root / 'home'
    bundles = root / 'bundles'
    bundles.mkdir()
    env = dict(os.environ, FM_HOME=str(home), HOME=str(root / 'user.[literal]#home'), TMPDIR=str(bundles))
    def invoke(task):
        return subprocess.run(['bash', 'bin/fm-plan-bundle.sh', task], env=env, text=True, capture_output=True)

    task = home / 'data' / 'publish'
    task.mkdir(parents=True)
    inputs = {
        'brief.md': f"home: {env['HOME']}/project\nhost: workstation.tailabc123.ts.net\nips: 100.64.0.1 100.127.255.254\npublic: 100.63.255.255 100.128.0.1\n",
        'report.md': '''tokens: ghp_synthetic gho_synthetic ghu_synthetic ghs_synthetic ghr_synthetic github_pat_synthetic xoxa-synthetic xoxb-synthetic xoxp-synthetic xoxr-synthetic xoxs-synthetic sk-synthetic
assignments: API_TOKEN=synthetic APP_SECRET=synthetic API_KEY=synthetic DB_PASSWORD=synthetic
quotes: DB_PASSWORD="alpha\\"secret phrase" APP_SECRET='alpha\\'secret phrase'
ampersands: DB_PASSWORD="alpha&beta" API_TOKEN='alpha&beta' SECRET=alpha&beta
ordinary: task-id ask-user mask-value
''',
        'plan.html': '<h1>Plan</h1>\n<p title="A &amp; B">&quot;safe text&quot;</p>\n<code>DB_PASSWORD="synthetic credential" </code>\n',
    }
    for name, text in inputs.items():
        (task / name).write_text(text)
    (task / 'ignored.txt').write_text('not a bundle artifact\n')
    p = invoke('publish')
    assert p.returncode == 0, p.stderr
    bundle = Path(p.stdout.split('bundle=', 1)[1].strip())
    assert stat.S_IMODE(bundle.stat().st_mode) == 0o700
    assert {p.name for p in bundle.iterdir()} == set(inputs)
    expected = {
        'brief.md': 'home: ~/project\nhost: <tailnet-host>\nips: <tailnet-ip> <tailnet-ip>\npublic: 100.63.255.255 100.128.0.1\n',
        'report.md': 'tokens: ' + ' '.join(['<redacted>'] * 12) + '\nassignments: ' + ' '.join(['<redacted>'] * 4) + '\nquotes: <redacted> <redacted>\nampersands: <redacted> <redacted> <redacted>\nordinary: task-id ask-user mask-value\n',
        'plan.html': '<h1>Plan</h1>\n<p title="A &amp; B">&quot;safe text&quot;</p>\n<code><redacted> </code>\n',
    }
    transcript.append('$ bash bin/fm-plan-bundle.sh publish')
    transcript.append(p.stdout.replace(str(bundle), '<isolated-private-bundle>').strip())
    for name in inputs:
        actual = (bundle / name).read_bytes()
        assert actual == expected[name].encode(), (name, actual)
        digest = hashlib.sha256(actual).hexdigest()
        assert f'{digest}  {name}\n' in p.stdout
        assert (task / name).read_text() == inputs[name]
        (evidence / ('bundle-' + name)).write_bytes(actual)
    transcript.append('Verified: directory mode 0700; only approved files; original bytes unchanged; every printed digest matches exported bytes.\n')
    results.append({'scenario': 'scrub-and-publish-local-bundle', 'result': 'pass'})
    shutil.rmtree(bundle)

    unsafe_cases = {
        'pem': ('report.md', 'safe heading\n\n-----BEGIN PRIVATE KEY-----\nSYNTHETIC-KEY-MATERIAL\n-----END PRIVATE KEY-----\n'),
        'array': ('report.md', 'declare -a API_KEY=(alpha secretphrase)\n'),
        'escaped-space': ('report.md', 'DB_PASSWORD=alpha\\ secretphrase\n'),
        'continued': ('report.md', 'DB_PASSWORD=alpha\\\nsecretphrase\n'),
        'shell-substitution': ('report.md', f'DB_PASSWORD=$(touch {root / "must-not-exist"}; echo "alpha secretphrase")\n'),
        'backtick': ('report.md', f'DB_PASSWORD=`touch {root / "must-not-exist"}; echo "alpha secretphrase"`\n'),
        'parameter': ('report.md', 'DB_PASSWORD=${SAVED_PASSWORD:-alpha secretphrase}\n'),
        'html-named': ('plan.html', '<code>DB_PASSWORD=&quotalpha secretphrase&quot</code>\n'),
        'html-decimal': ('plan.html', '<code>DB_PASSWORD=&#34alpha secretphrase&#34</code>\n'),
        'html-hex': ('plan.html', '<code>DB_PASSWORD=&#x22private secretphrase&#x22</code>\n'),
        'residual-home': ('report.md', '/home/another-user/project\n'),
        'residual-host': ('report.md', 'node.other.ts.net\n'),
    }
    for key, (name, text) in unsafe_cases.items():
        directory = home / 'data' / key
        directory.mkdir(parents=True)
        (directory / 'brief.md').write_text('safe brief\n')
        (directory / name).write_text(text)
        p = invoke(key)
        assert p.returncode == 1, key
        assert not p.stdout, key
        assert not list(bundles.iterdir()), key
        assert not (root / 'must-not-exist').exists(), key
        assert (directory / name).read_text() == text
        if key == 'pem':
            assert p.stderr == 'error: bundle refused: private key marker in report.md:3\n'
        else:
            assert p.stderr == f'error: bundle refused: residual leak or unreadable file in {name}\n'
        transcript.append(f'$ bash bin/fm-plan-bundle.sh {key}\nexit=1; stdout empty; {p.stderr.strip()}\nNo bundle retained; input unchanged; no artifact command executed.\n')
        results.append({'scenario': key, 'result': 'pass'})

    for mode, forge in [('direct-PR', 'none'), ('no-mistakes', 'none'), ('direct-PR', 'forgejo'), ('no-mistakes', 'forgejo'), ('direct-PR', 'gerrit'), ('no-mistakes', 'gerrit'), ('local-only', 'none')]:
        command = ['bash', '-c', '. bin/fm-dod-lib.sh; fm_dod_block "$1" validation fm/validation "$2"', 'render', mode, forge]
        p = subprocess.run(command, env=env, text=True, capture_output=True)
        assert p.returncode == 0 and not p.stderr, (mode, forge, p.stderr)
        should_have = mode != 'local-only' and forge != 'gerrit'
        assert p.stdout.splitlines().count(expected_provenance) == int(should_have)
        if not should_have:
            assert '## Provenance' not in p.stdout
        (evidence / f'delivery-{mode}-{forge}.md').write_text(p.stdout)
        transcript.append(f'$ fm_dod_block {mode} validation fm/validation {forge}\nexit=0; exact provenance line count={int(should_have)}; rendered output saved.\n')
        results.append({'scenario': f'delivery-{mode}-{forge}', 'result': 'pass'})

(evidence / 'manual-validation.log').write_text('\n'.join(transcript) + '\n')
(evidence / 'manual-results.json').write_text(json.dumps(results, indent=2) + '\n')
print('Real bundle CLI and delivery renderer checks passed; evidence saved and temporary home removed.')
