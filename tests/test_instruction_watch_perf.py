#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstructionPerformance(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.home = self.work / 'home'
        self.state = self.work / 'state'
        self.repo = self.work / 'repo'
        self.repo.mkdir()
        self.home.mkdir()
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), INSTRUCTION_WATCH_STATE=str(self.state),
                        INSTRUCTION_WATCH_LOG=str(self.work / 'changes.log'),
                        INSTRUCTION_WATCH_ALERT='/usr/bin/true', INSTRUCTION_WATCH_CHAT='all',
                        CLAUDEB_DIR=str(self.work / 'claudeb'), TOKENMAP_RATES=str(self.work / 'no-rates'))
        for key in ('CLAUDEB_WORKER', 'GROK_WORKER', 'CLAUDE_LAUNCHER_SESSION'):
            self.env.pop(key, None)

    def put(self, path, content='rules\n'):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], env=self.env,
                                       stderr=subprocess.DEVNULL, text=True)

    def listing(self, function='instruction_repo_files', **env):
        output = subprocess.check_output(['bash', '-c', '. "$1"; ' + function + ' "$2"',
                                          '_', str(ROOT / 'share/instruction-files.sh'), self.repo.name],
                                         cwd=self.work, env={**self.env, **env}, text=True)
        return {str(Path(p).relative_to(self.repo.name)) for p in output.splitlines()}

    def walk(self):
        return self.listing('_instruction_find_files')

    def hook(self, mode, **env):
        return subprocess.run(['bash', str(ROOT / 'bin/instruction-watch.sh'), mode],
                              input=json.dumps({'session_id': 'perf', 'cwd': str(self.repo)}),
                              text=True, capture_output=True, env={**self.env, **env})

    def context(self, result):
        self.assertEqual(0, result.returncode, result.stderr)
        if not result.stdout:
            return ''
        return json.loads(result.stdout)['hookSpecificOutput']['additionalContext']

    def shim(self, name, body):
        directory = self.work / 'shim'
        directory.mkdir(exist_ok=True)
        binary = shutil.which(name)
        self.put(directory / name, '#!/bin/bash\n' + body.replace('@REAL@', binary))
        (directory / name).chmod(0o755)
        return str(directory) + ':' + self.env['PATH']

    def test_git_inventory_and_live_ignore_changes(self):
        self.git('init', '-q')
        self.put(self.repo / '.gitignore', 'CLAUDE.local.md\n.claude/\noutput/\n*.markdown\n')
        names = ['CLAUDE.md', 'CLAUDE.local.md', 'pkg/claude.MD', 'pkg/SKILL.md',
                 '.claude/a/b/policy.markdown', '.claude/review-debt-ignore',
                 '.claude/a/CLAUDE.local.md', '.claude/rules/ignored.md',
                 'tracked/CLAUDE.local.md']
        for name in names:
            self.put(self.repo / name)
        self.git('add', '-f', 'tracked/CLAUDE.local.md')
        for name in ['output/CLAUDE.md', 'output/.claude/policy.md', 'node_modules/CLAUDE.md',
                     'worktrees/CLAUDE.md', '.claude/worktrees/CLAUDE.md',
                     '.claude/node_modules/SKILL.md', 'ordinary.md', 'other.markdown']:
            self.put(self.repo / name)
        (self.repo / 'alias').symlink_to(self.repo / 'pkg', target_is_directory=True)
        (self.repo / 'linked-CLAUDE.md').symlink_to(self.repo / 'CLAUDE.md')
        self.assertEqual(set(names), self.listing())
        self.assertEqual(self.walk() - {'output/CLAUDE.md', 'output/.claude/policy.md'}, self.listing())
        self.put(self.repo / '.gitignore', 'CLAUDE.local.md\n.claude/\n*.markdown\n')
        self.assertEqual(set(names) | {'output/CLAUDE.md', 'output/.claude/policy.md'}, self.listing())
        self.assertEqual(self.walk(), self.listing())
        self.put(self.repo / 'new/CLAUDE.md')
        self.assertIn('new/CLAUDE.md', self.listing())

    def test_failing_git_falls_back_to_the_walk(self):
        self.git('init', '-q')
        self.put(self.repo / '.gitignore', 'output/\n')
        for name in ('CLAUDE.md', 'output/CLAUDE.md', '.claude/rule.md'):
            self.put(self.repo / name)
        path = self.shim('git', 'case "$*" in *" -o -i "*) exit 128 ;; esac\nexec @REAL@ "$@"\n')
        self.assertEqual({'CLAUDE.md', 'output/CLAUDE.md', '.claude/rule.md'}, self.listing(PATH=path))

    def test_repository_under_a_claude_directory(self):
        self.repo = self.work / '.claude/worktrees/task'
        self.repo.mkdir(parents=True)
        self.git('init', '-q')
        self.put(self.repo / '.gitignore', 'build/\n.claude/\n')
        for name in ('notes.md', 'docs/plan.markdown', 'build/out.md', 'CLAUDE.md', '.claude/rule.md'):
            self.put(self.repo / name)

        def listing():
            output = subprocess.check_output(['bash', '-c', '. "$1"; instruction_repo_files "$2"', '_',
                                              str(ROOT / 'share/instruction-files.sh'), str(self.repo)],
                                             env=self.env, text=True)
            return set(output.splitlines())
        expected = {str(self.repo / 'CLAUDE.md'), str(self.repo / '.claude/rule.md')}
        self.assertEqual(expected, listing())
        shutil.rmtree(self.repo / '.git')
        self.assertEqual(expected, listing())

    def test_nested_repository_and_submodule(self):
        self.git('init', '-q')
        for name in ('nested', 'module'):
            child = self.repo / name
            child.mkdir()
            subprocess.run(['git', '-C', str(child), 'init', '-q'], env=self.env, check=True)
            self.put(child / 'CLAUDE.md')
        self.git('update-index', '--add', '--cacheinfo', '160000,' + '1' * 40 + ',module')
        self.assertEqual({'nested/CLAUDE.md', 'module/CLAUDE.md'}, self.listing())

    def test_batched_home_names_keep_unwatchable_spellings(self):
        for name in ('plain.md', 'tab\tname.md', 'line\nname.md'):
            self.put(self.home / '.claude/docs' / name)
        out = subprocess.check_output(['bash', '-c', '. "$1"; _instruction_class_files "$HOME"',
                                       '_', str(ROOT / 'share/instruction-files.sh')],
                                      env=self.env, text=True)
        self.assertEqual({'plain.md', 'tab?name.md', 'line?name.md'},
                         {Path(line).name for line in out.splitlines()})

    def test_home_walk_skips_the_trees_nothing_loads(self):
        kept = {self.put(self.home / '.claude' / p) for p in (
            'agents/a.md', 'plugins/cache/mp/p/1.0/skills/s/SKILL.md', 'skills/s/.hidden/x.md')}
        for p in ('file-history/sess/notes.md', 'plugins/marketplaces/mp/plugins/p/skills/s/SKILL.md',
                  'plugins/.trash/1/p/SKILL.md', '.premove-backup-1/skills/s/SKILL.md'):
            self.put(self.home / '.claude' / p)
        output = subprocess.check_output(['bash', '-c', '. "$1"; _instruction_class_files "$2"', '_',
                                          str(ROOT / 'share/instruction-files.sh'), str(self.home)],
                                         env=self.env, text=True)
        self.assertEqual({str(p) for p in kept}, set(output.splitlines()))

    def test_home_walk_prunes_under_a_long_or_odd_home(self):
        for name in ('a' * 250, 'we(ird)[x]+y.z{1}'):
            home = self.work / name
            kept = self.put(home / '.claude/agents/a.md')
            self.put(home / '.claude/plugins/marketplaces/mp/SKILL.md')
            self.put(home / '.claude/.backup/SKILL.md')
            output = subprocess.check_output(['bash', '-c', '. "$1"; _instruction_class_files "$2"', '_',
                                              str(ROOT / 'share/instruction-files.sh'), str(home)],
                                             env=self.env, text=True)
            self.assertEqual([str(kept)], output.splitlines(), name)

    def test_a_baseline_row_under_an_unloaded_tree_is_dropped(self):
        agent = self.put(self.home / '.claude/agents/a.md')
        catalog = self.put(self.home / '.claude/plugins/marketplaces/mp/plugins/p/skills/s/SKILL.md')
        self.assertEqual(0, self.hook('baseline').returncode)
        baseline = self.state / 'session-perf.tsv'
        row = '\t'.join(['1.5', '5', '1', '1', '0' * 64, '-', str(catalog), str(catalog)])
        baseline.write_text(baseline.read_text() + row + '\n')
        catalog.write_text('pulled by the harness\n')
        agent.write_text('changed\n')
        context = self.context(self.hook('check'))
        self.assertIn('CHANGED ' + str(agent), context)
        self.assertNotIn(str(catalog), context)
        self.assertNotIn(str(catalog), baseline.read_text())

    def test_a_session_inside_an_unloaded_tree_watches_none_of_it(self):
        self.home = self.home.resolve()
        self.env['HOME'] = str(self.home)
        self.repo = self.home / '.claude/plugins/marketplaces/mp'
        self.repo.mkdir(parents=True)
        self.git('init', '-q')
        self.put(self.repo / 'CLAUDE.md')
        self.git('add', 'CLAUDE.md')
        agent = self.put(self.home / '.claude/agents/a.md')
        self.assertEqual(0, self.hook('baseline').returncode)
        self.assertEqual('', self.context(self.hook('check')))
        agent.write_text('changed\n')
        self.assertNotIn('ADDED', self.context(self.hook('check')))

    def test_backslash_name_is_hashed_and_watched(self):
        odd = self.put(self.home / '.claude/docs/a\\b.md')
        self.assertEqual(0, self.hook('baseline').returncode)
        baseline = (self.state / 'session-perf.tsv').read_text()
        self.assertNotIn('#unwatchable\t' + str(odd), baseline)
        row = next(line.split('\t') for line in baseline.splitlines() if line.split('\t')[6:7] == [str(odd)])
        self.assertRegex(row[4], '^[0-9a-f]{64}$')
        odd.write_text('changed\n')
        self.assertEqual(1, self.context(self.hook('check')).count('CHANGED ' + str(odd) + ' ('))

    def test_non_git_inventory(self):
        for name in ['CLAUDE.local.md', 'pkg/CLAUDE.md', '.claude/deep/rule.markdown',
                     'node_modules/CLAUDE.md', 'worktrees/CLAUDE.md']:
            self.put(self.repo / name)
        self.assertEqual({'CLAUDE.local.md', 'pkg/CLAUDE.md', '.claude/deep/rule.markdown'}, self.listing())

    def test_dependency_trees_are_not_watched(self):
        deps = ['vendor/acme/lib/CLAUDE.md', 'vendor/acme/lib/.claude/skills/x/SKILL.md',
                'node_modules/pkg/SKILL.md', '.venv/lib/python3.12/site-packages/tool/CLAUDE.md']
        for name in ['CLAUDE.md', 'src/vendors/CLAUDE.md'] + deps:
            self.put(self.repo / name)
        self.assertEqual({'CLAUDE.md', 'src/vendors/CLAUDE.md'}, self.listing())
        self.git('init', '-q')
        self.git('add', '-f', '.')
        self.assertEqual({'CLAUDE.md', 'src/vendors/CLAUDE.md'}, self.listing())

    def test_new_session_keeps_its_own_trust_policy(self):
        self.put(self.home / '.claude/docs/old.md')
        self.assertEqual(0, self.hook('baseline').returncode)
        quoted = self.put(self.home / ".claude/docs/it's-new.md")
        result = subprocess.run(['bash', str(ROOT / 'bin/instruction-watch.sh'), 'baseline'],
                                input=json.dumps({'session_id': 'new-session'}), text=True,
                                capture_output=True, env=self.env)
        self.assertEqual(0, result.returncode, result.stderr)
        baseline = (self.state / 'session-new-session.tsv').read_text()
        row = next(line.split('\t') for line in baseline.splitlines() if str(quoted) in line)
        self.assertEqual('1', row[3])
        self.assertTrue(any((self.state / 'snapshot').glob("it's-new.md-*")))

    def test_one_stat_and_no_hash_for_quiet_check(self):
        self.git('init', '-q')
        for i in range(40):
            self.put(self.home / f'.claude/docs/{i}.md')
        self.assertEqual(0, self.hook('baseline').returncode)
        log = self.work / 'exec.log'
        path = self.shim('stat', 'echo stat >> "$PROBE_LOG"\nexec @REAL@ "$@"\n')
        self.shim('shasum', 'echo hash >> "$PROBE_LOG"\nexec @REAL@ "$@"\n')
        self.shim('find', 'echo find >> "$PROBE_LOG"\nexec @REAL@ "$@"\n')
        self.shim('git', 'case " $* " in *" ls-files "*) echo ls-files >> "$PROBE_LOG" ;; esac\nexec @REAL@ "$@"\n')
        trace = self.put(self.work / 'trace.sh', 'set -x\n')
        result = self.hook('check', PATH=path, PROBE_LOG=str(log), BASH_ENV=str(trace))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stdout)
        self.assertEqual(['stat', 'stat'], log.read_text().splitlines())
        self.assertFalse(' pin ' in result.stderr, 'quiet check performed per-file pin work')

    def test_reused_enumeration_still_sees_every_arrival(self):
        self.git('init', '-q')
        self.put(self.repo / '.gitignore', 'output/\n*.log\n.claude/\n')
        self.put(self.repo / 'output/CLAUDE.md')
        self.put(self.repo / 'logs/run.log')
        self.put(self.repo / 'pkg/CLAUDE.md')
        self.put(self.repo / '.claude/rules/a.md')
        self.put(self.home / '.claude/skills/old/SKILL.md')
        (self.repo / 'empty/deeper').mkdir(parents=True)
        self.assertEqual(0, self.hook('baseline').returncode)
        self.assertEqual('', self.hook('check').stdout)
        arrivals = [
            lambda: self.put(self.repo / 'pkg/sub/CLAUDE.md'),
            lambda: self.put(self.repo / 'logs/CLAUDE.md'),
            lambda: self.put(self.repo / 'empty/deeper/x/CLAUDE.md'),
            lambda: self.put(self.repo / '.claude/rules/b.md'),
            lambda: self.put(self.home / '.claude/skills/new/SKILL.md'),
            lambda: (self.put(self.repo / '.gitignore', '*.log\n.claude/\n'), self.repo / 'output/CLAUDE.md')[1],
        ]
        for arrive in arrivals:
            added = arrive()
            context = self.context(self.hook('check'))
            self.assertTrue(any('ADDED ' + str(p) in context for p in (added, added.resolve())), context)
            self.assertEqual('', self.hook('check').stdout)

    def test_spent_budget_leaves_the_rest_for_the_next_call(self):
        self.git('init', '-q')
        docs = [self.put(self.home / f'.claude/docs/{n}.md') for n in 'abc']
        self.assertEqual(0, self.hook('baseline').returncode)
        for doc in docs:
            doc.write_text('changed ' + doc.name + '\n')
        docs[0].unlink()
        added = [self.put(self.home / f'.claude/docs/new-{n}.md') for n in 'xy']
        expect = ['DELETED ' + str(docs[0])] + ['CHANGED ' + str(p) for p in docs[1:]] + \
                 ['ADDED ' + str(p) for p in added]
        seen = []
        for _ in expect:
            context = self.context(self.hook('check', INSTRUCTION_WATCH_BUDGET='0'))
            hits = [e for e in expect if e + ' ' in context or context.endswith(e) or e + ';' in context
                    or e + '.' in context]
            self.assertEqual(1, len(hits), context)
            seen += hits
        self.assertEqual(sorted(expect), sorted(seen))
        self.assertEqual('', self.hook('check', INSTRUCTION_WATCH_BUDGET='0').stdout)
        self.assertEqual(len(expect), len((self.state / 'events.jsonl').read_text().splitlines()))

    def test_unspent_budget_reports_every_change_in_one_call(self):
        self.git('init', '-q')
        docs = [self.put(self.home / f'.claude/docs/{n}.md') for n in 'abc']
        self.assertEqual(0, self.hook('baseline').returncode)
        for doc in docs:
            doc.write_text('changed ' + doc.name + '\n')
        added = self.put(self.home / '.claude/docs/new.md')
        context = self.context(self.hook('check'))
        for doc in docs:
            self.assertEqual(1, context.count('CHANGED ' + str(doc) + ' ('))
        self.assertEqual(1, context.count('ADDED ' + str(added)))
        self.assertEqual('', self.hook('check').stdout)


if __name__ == '__main__':
    unittest.main()
