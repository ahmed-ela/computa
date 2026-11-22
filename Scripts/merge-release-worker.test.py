"""Exercise release discovery, recovery and replay against a local Git remote."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("worker", Path(__file__).with_name("merge-release-worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class MergeQueueTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.origin = root / "repository"
        self.origin.mkdir()
        self.git("init", "-q", "-b", worker.BRANCH)
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "commit.gpgsign", "false")
        scripts = self.origin / "Scripts"
        scripts.mkdir()
        (scripts / "release-merged-mac.py").write_text(
            "from pathlib import Path\nimport sys\nstate = Path(sys.argv[1])\n"
            "with (state / 'attempts').open('a') as f: f.write(sys.argv[2] + '\\n')\n"
            "sys.exit((state / 'fail').exists())\n")
        self.git("add", ".")
        anchor = self.commit("baseline")
        self.state = root / "service"
        self.state.mkdir(mode=0o700)
        (self.state / "release-service").touch()
        real_output = worker.output

        def output(*args, cwd=None):
            if args[0] == "bun":
                return real_output("git", "rev-parse", "HEAD", cwd=cwd)
            return real_output(*args, cwd=cwd)

        for key, value in (("REMOTE", str(self.origin)), ("ANCHOR", anchor), ("output", output)):
            patcher = patch.object(worker, key, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(worker, "report")
        self.report = patcher.start()
        self.addCleanup(patcher.stop)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.origin, text=True).strip()

    def commit(self, title):
        self.git("commit", "-q", "--allow-empty", "-m", title)
        return self.git("rev-parse", "HEAD")

    def attempts(self):
        return (self.state / "attempts").read_text().splitlines()

    def test_offline_catchup_skips_unmerged_branches_and_does_not_republish(self):
        first = self.commit("first")
        self.git("switch", "-q", "-c", "open-pr")
        self.commit("unmerged")
        self.git("switch", "-q", worker.BRANCH)
        second = self.commit("second")
        worker.run(self.state)
        worker.run(self.state)
        self.assertEqual(self.attempts(), [first, second])
        self.assertEqual([call.args[1] for call in self.report.call_args_list],
                         ["pending", "success", "pending", "success"])

    def test_failure_backs_off_and_later_merges_are_processed(self):
        failed = self.commit("broken build")
        (self.state / "fail").touch()
        with self.assertRaises(subprocess.CalledProcessError):
            worker.run(self.state)
        worker.run(self.state)
        self.assertEqual(self.attempts(), [failed])
        self.assertEqual(self.report.call_args.args[1], "failure")
        (self.state / "fail").unlink()
        fixed = self.commit("fix")
        worker.run(self.state)
        self.assertEqual(self.attempts(), [failed, failed, fixed])

    def test_unmarked_directory_is_untouched(self):
        (self.state / "release-service").unlink()
        with self.assertRaises(RuntimeError):
            worker.run(self.state)
        self.assertEqual(list(self.state.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
