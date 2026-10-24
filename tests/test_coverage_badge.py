"""커버리지 배지가 누락된 집계나 중복 집계를 성공으로 표시하지 않는지 확인한다."""
import json
from pathlib import Path
import tempfile
import unittest
import os
from unittest.mock import patch
import subprocess
import types

workflow = Path(__file__).parents[1] / ".github/workflows/reusable-java-test.yaml"
script = subprocess.check_output([
    "ruby", "-ryaml", "-e",
    'puts YAML.load_file(ARGV[0])["jobs"]["test"]["steps"].find { |s| s["id"] == "coverage" }["run"]',
    str(workflow),
], text=True)
module = types.ModuleType("coverage_badge")
exec(script.split("python3 <<'PYTHON'\n", 1)[1].rsplit("PYTHON", 1)[0], module.__dict__)
generate = module.generate


class CoverageBadgeTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.report = self.root / "report.xml"
        self.output = self.root / "badge"

    def test_패키지_집계를_중복_합산하지_않는다(self):
        self.report.write_text('<report><package><counter type="LINE" covered="10" missed="0"/></package><counter type="LINE" covered="8" missed="2"/></report>')
        generate(self.report, self.output, "검증커밋")
        result = json.loads((self.output / "summary.json").read_text(encoding="utf-8"))
        self.assertEqual(result["total"], 10)
        self.assertEqual(result["line_percent"], 80)
        self.assertEqual(result["source_sha"], "검증커밋")
        self.assertIn("80.0%", (self.output / "jacoco.svg").read_text())

    def test_전체_집계가_없으면_배지를_만들지_않는다(self):
        self.report.write_text('<report><package><counter type="LINE" covered="10" missed="0"/></package></report>')
        with self.assertRaisesRegex(ValueError, "전체 LINE"):
            generate(self.report, self.output, "commit")
        self.assertFalse(self.output.exists())

    def test_빈_집계를_100퍼센트로_표시하지_않는다(self):
        self.report.write_text('<report><counter type="LINE" covered="0" missed="0"/></report>')
        with self.assertRaises(ValueError):
            generate(self.report, self.output, "commit")

    def test_반올림으로_100퍼센트가_되지_않는다(self):
        self.report.write_text('<report><counter type="LINE" covered="9999" missed="1"/></report>')
        generate(self.report, self.output, "commit")
        result = json.loads((self.output / "summary.json").read_text(encoding="utf-8"))
        self.assertEqual(result["line_percent"], 99.9)

    def test_라인과_분기_수치를_구분한다(self):
        self.report.write_text('<report><counter type="LINE" covered="9" missed="1"/><counter type="BRANCH" covered="3" missed="1"/></report>')
        generate(self.report, self.output, "commit")
        result = json.loads((self.output / "summary.json").read_text(encoding="utf-8"))
        self.assertEqual(result["line_percent"], 90)
        self.assertEqual(result["branch_percent"], 75)
        self.assertIn("75.0%", (self.output / "jacoco-branches.svg").read_text())

    def test_분기_없는_코드는_측정불가로_표시한다(self):
        self.report.write_text('<report><counter type="LINE" covered="9" missed="1"/></report>')
        generate(self.report, self.output, "commit")
        result = json.loads((self.output / "summary.json").read_text(encoding="utf-8"))
        self.assertIsNone(result["branch_percent"])
        self.assertIn("n/a", (self.output / "jacoco-branches.svg").read_text())



class CoverageDiscoveryTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, previous)
        env = patch.dict(os.environ, {
            "MODULE": "", "GITHUB_SHA": "source-sha",
            "GITHUB_OUTPUT": str(self.root / "outputs"),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
        })
        env.start()
        self.addCleanup(env.stop)

    def report(self, name, covered=8):
        path = Path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'<report><counter type="LINE" covered="{covered}" missed="2"/></report>')

    def test_no_jacoco_is_optional(self):
        module.main()
        self.assertFalse(Path("outputs").exists())

    def test_single_standard_report(self):
        self.report("build/reports/jacoco/test/jacocoTestReport.xml")
        module.main()
        self.assertEqual(Path("outputs").read_text(), "available=true\n")
        data = json.loads(Path("build/reports/coverage-badge/summary.json").read_text())
        self.assertEqual(data["source_sha"], "source-sha")

    def test_aggregate_wins_without_double_counting(self):
        self.report("build/reports/jacoco/root/jacoco.xml")
        self.report("build/reports/jacoco/test/jacocoTestReport.xml", 99)
        module.main()
        data = json.loads(Path("build/reports/coverage-badge/summary.json").read_text())
        self.assertEqual(data["covered"], 8)

    def test_ambiguous_reports_skip_badge(self):
        self.report("build/reports/jacoco/one/report.xml")
        self.report("build/reports/jacoco/two/report.xml")
        module.main()
        self.assertFalse(Path("outputs").exists())

    def test_module_ignores_root_and_sibling_reports(self):
        self.report("build/reports/jacoco/root/jacoco.xml", 99)
        self.report("other/build/reports/jacoco/test/report.xml", 99)
        self.report("gateway/build/reports/jacoco/test/report.xml", 3)
        with patch.dict(os.environ, {"MODULE": "gateway"}):
            module.main()
        data = json.loads(Path("build/reports/coverage-badge/summary.json").read_text())
        self.assertEqual(data["covered"], 3)

    def test_invalid_xml_fails_without_success_output(self):
        self.report("build/reports/jacoco/test/report.xml")
        Path("build/reports/jacoco/test/report.xml").write_text("invalid")
        with self.assertRaises(module.ET.ParseError):
            module.main()
        self.assertFalse(Path("outputs").exists())


class CoveragePublicationTest(unittest.TestCase):
    def test_publication_guards_and_concurrent_modules(self):
        publisher = workflow.with_name("reusable-java-coverage.yaml")
        script = subprocess.check_output([
            "ruby", "-ryaml", "-e",
            'puts YAML.load_file(ARGV[0])["jobs"]["publish"]["steps"].last["with"]["script"]',
            str(publisher),
        ], text=True)
        harness = r"""
const assert = require('node:assert/strict');
const script = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
const execute = new (Object.getPrototypeOf(async function() {}).constructor)(
  'require', 'github', 'context', 'core', 'process', script);
async function scenario(options = {}) {
  const calls = [];
  let conflicts = options.conflicts || 0;
  let previous = options.previous;
  const fail = status => Object.assign(new Error('API failure'), {status});
  const git = {
    getRef: async ({ref}) => {
      if (ref === 'heads/main') return {data: {object: {sha: options.stale ? 'new-main' : 'sha'}}};
      if (!previous) throw fail(404);
      return {data: {object: {sha: previous}}};
    },
    getCommit: async ({commit_sha}) => ({data: {tree: {sha: `tree-${commit_sha}`}}}),
    createTree: async args => { calls.push(['tree', args]); return {data: {sha: 'tree'}}; },
    createCommit: async args => { calls.push(['commit', args]); return {data: {sha: 'commit'}}; },
    createRef: async args => { calls.push(['create', args]); },
    updateRef: async args => {
      if (options.denied) throw fail(403);
      if (conflicts-- > 0) { previous = 'other-module'; throw fail(422); }
      calls.push(['update', args]);
    }
  };
  const summary = {source_sha: options.wrongSha ? 'wrong' : 'sha', line_percent: 80, branch_percent: 50};
  const fs = {readFileSync: name => name.endsWith('summary.json') ? JSON.stringify(summary) : '<svg/>'};
  const core = {notice() {}, summary: {addHeading() {return this}, addRaw() {return this}, write() {}}};
  await execute(() => fs, {rest: {git}}, {repo: {owner: 'o', repo: 'r'}, sha: 'sha'}, core,
    {env: {MODULE: options.module || ''}});
  return calls;
}
(async () => {
  const initial = await scenario();
  assert.equal(initial.filter(c => c[0] === 'create').length, 1);
  assert.equal(initial[0][1].tree[0].path, 'jacoco.svg');
  assert.deepEqual(await scenario({stale: true}), []);
  await assert.rejects(scenario({wrongSha: true}), /기준 커밋/);
  await assert.rejects(scenario({previous: 'old', denied: true}), /API failure/);
  const retry = await scenario({previous: 'old', module: 'gateway', conflicts: 1});
  const trees = retry.filter(c => c[0] === 'tree').map(c => c[1]);
  assert.equal(trees.length, 2);
  assert.equal(trees[0].base_tree, 'tree-old');
  assert.equal(trees[1].base_tree, 'tree-other-module');
  assert.equal(trees[1].tree[0].path, 'gateway/jacoco.svg');
  assert.equal(retry.find(c => c[0] === 'update')[1].force, false);
})().catch(error => {console.error(error); process.exit(1)});
"""
        subprocess.run(["node", "-e", harness], input=json.dumps(script), text=True, check=True)

if __name__ == "__main__":
    unittest.main()
