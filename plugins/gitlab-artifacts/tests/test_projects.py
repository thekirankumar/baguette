import importlib.util
import io
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.parse
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("gitlab_projects", ROOT / "bin/download.py")
download = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(download)


class ProjectTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=ROOT / "tests")
        self.addCleanup(temporary.cleanup)
        self.workspace = Path(temporary.name)
        self.env = {"BAGUETTE_RUN_DIR": str(self.workspace), "GITLAB_HOST": "gitlab.example.com", "GITLAB_TOKEN": "secret-token"}
        self.config = {"host": "gitlab.example.com", "projectIds": [301], "maxArchiveBytes": 1024 * 1024}
        self.request = {"version": 1, "command": "gitlab-artifacts:install", "udid": "simulator-id",
                        "workspace": str(self.workspace), "args": {"projectId": "ios/PhonePe", "jobId": 456}}
        self.project = {"id": 301, "name": "PhonePe", "path": "phonepe", "path_with_namespace": "ios/PhonePe"}
        self.routes = {"projects/ios%2FPhonePe": self.project}
        self.calls = []

    def archive(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            entry = zipfile.ZipInfo("MyApp.app/MyApp")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o755) << 16
            archive.writestr(entry, b"executable")
        return data.getvalue()

    def search(self, name, page=1):
        return f"projects?search={urllib.parse.quote(name, safe='')}&simple=true&per_page=100&page={page}&order_by=id&sort=asc"

    def run_download(self, failures=None):
        failures = failures or {}
        def spawn(argv, **kwargs):
            self.calls.append(argv)
            endpoint = argv[-1]
            self.assertEqual(argv[:-1], ["glab", "api", "--method", "GET", "--hostname", "gitlab.example.com"])
            self.assertEqual(kwargs["env"]["GITLAB_TOKEN"], "secret-token")
            self.assertFalse(kwargs.get("shell", False))
            code, stderr = failures.get(endpoint, (0, b""))
            if stderr:
                kwargs["stderr"].write(stderr)
                kwargs["stderr"].flush()
            if code == 0:
                if endpoint.endswith("/artifacts"):
                    payload = self.archive()
                else:
                    self.assertIn(endpoint, self.routes)
                    value = self.routes[endpoint]
                    payload = value if isinstance(value, bytes) else json.dumps(value).encode()
                kwargs["stdout"].write(payload)
                kwargs["stdout"].flush()
            process = mock.Mock()
            process.wait.return_value = code
            process.poll.return_value = code
            return process
        with mock.patch.object(download.subprocess, "Popen", side_effect=spawn):
            result = download.run(self.request, self.config, self.env)
        self.assertEqual(json.loads((self.workspace / "result.json").read_text()), result)
        self.assertNotIn("secret-token", json.dumps(result))
        return result

    def assert_prepared(self, result):
        self.assertTrue(result["ok"], result.get("message"))
        self.assertEqual((self.workspace / result["output"]["path"] / "MyApp").read_bytes(), b"executable")
        self.assertEqual(self.calls[-1][-1], "projects/301/jobs/456/artifacts")

    def test_should_install_a_project_path_after_resolving_its_numeric_identity(self):
        self.assert_prepared(self.run_download())
        self.assertEqual([call[-1] for call in self.calls], ["projects/ios%2FPhonePe", "projects/301/jobs/456/artifacts"])

    def test_should_install_a_nested_project_path_without_double_encoding(self):
        self.request["args"]["projectId"] = "group/sub_group/My.App"
        self.routes = {"projects/group%2Fsub_group%2FMy.App": dict(self.project, path_with_namespace="group/sub_group/My.App")}
        self.assert_prepared(self.run_download())

    def test_should_install_a_numeric_project_without_a_metadata_lookup(self):
        self.request["args"]["projectId"] = "301"
        self.assert_prepared(self.run_download())
        self.assertEqual(len(self.calls), 1)

    def test_should_install_a_unique_exact_project_name_and_ignore_partial_matches(self):
        self.request["args"]["projectId"] = "PhonePe"
        self.routes = {self.search("PhonePe"): [self.project, dict(self.project, id=302, name="PhonePe Tests", path="phonepe-tests")]}
        self.assert_prepared(self.run_download())

    def test_should_match_names_or_project_slugs_case_insensitively(self):
        self.request["args"]["projectId"] = "PHONEPE"
        self.routes = {self.search("PHONEPE"): [self.project]}
        self.assert_prepared(self.run_download())

    def test_should_encode_project_display_names_in_search_queries(self):
        self.request["args"]["projectId"] = "PhonePe App"
        self.routes = {self.search("PhonePe App"): [dict(self.project, name="PhonePe App")]}
        self.assert_prepared(self.run_download())
        self.assertIn("search=PhonePe%20App&", self.calls[0][-1])

    def test_should_refuse_ambiguous_names_without_selecting_an_allowlisted_candidate(self):
        self.request["args"]["projectId"] = "PhonePe"
        self.routes = {self.search("PhonePe"): [self.project, dict(self.project, id=302, path_with_namespace="other/phonepe")]}
        result = self.run_download()
        self.assertFalse(result["ok"])
        for detail in ("ambiguous", "ios/PhonePe", "other/phonepe", "full project path"):
            self.assertIn(detail, result["message"])
        self.assertFalse((self.workspace / "artifacts.zip").exists())

    def test_should_refuse_a_name_with_no_exact_match(self):
        self.request["args"]["projectId"] = "PhonePe"
        self.routes = {self.search("PhonePe"): [dict(self.project, name="PhonePe Tests", path="phonepe-tests")]}
        result = self.run_download()
        self.assertFalse(result["ok"])
        self.assertIn("No exact project", result["message"])
        self.assertFalse((self.workspace / "artifacts.zip").exists())

    def test_should_check_later_search_pages_before_claiming_a_unique_name(self):
        self.request["args"]["projectId"] = "PhonePe"
        first = [dict(self.project, id=1000 + index, name=f"PhonePe {index}", path=f"phonepe-{index}") for index in range(99)]
        self.routes = {self.search("PhonePe"): first + [self.project], self.search("PhonePe", 2):
                       [dict(self.project, id=302, path_with_namespace="other/phonepe")]}
        result = self.run_download()
        self.assertFalse(result["ok"])
        self.assertIn("ambiguous", result["message"])
        self.assertEqual(len(self.calls), 2)

    def test_should_install_a_unique_name_found_on_a_later_search_page(self):
        self.request["args"]["projectId"] = "PhonePe"
        first = [dict(self.project, id=1000 + index, name=f"PhonePe {index}", path=f"phonepe-{index}") for index in range(100)]
        self.routes = {self.search("PhonePe"): first, self.search("PhonePe", 2): [self.project]}
        self.assert_prepared(self.run_download())

    def test_should_enforce_the_numeric_allowlist_after_project_resolution(self):
        self.routes["projects/ios%2FPhonePe"] = dict(self.project, id=999)
        result = self.run_download()
        self.assertFalse(result["ok"])
        self.assertIn("Unapproved project", result["message"])
        self.assertIn("999", result["message"])
        self.assertFalse((self.workspace / "artifacts.zip").exists())

    def test_should_allow_paths_under_wildcard_policy_but_not_when_downloads_are_disabled(self):
        self.config["projectIds"] = "*"
        self.assert_prepared(self.run_download())
        self.config["projectIds"] = []
        self.calls.clear()
        self.assertFalse(self.run_download()["ok"])
        self.assertEqual(self.calls, [])

    def test_should_report_resolution_errors_with_glab_stderr_and_credentials_redacted(self):
        result = self.run_download({"projects/ios%2FPhonePe": (1, b"HTTP 404 project not found secret-token")})
        self.assertFalse(result["ok"])
        for detail in ("GitLab project resolution failed", "HTTP 404", "exit status: 1", "projects/ios%2FPhonePe"):
            self.assertIn(detail, result["message"])
        self.assertLessEqual(len(result["message"].encode()), 4096)

    def test_should_refuse_malformed_project_metadata_without_downloading(self):
        for value in (b"not JSON", [], {"id": True}, dict(self.project, id="301"), dict(self.project, path_with_namespace=None)):
            with self.subTest(value=value):
                self.routes["projects/ios%2FPhonePe"] = value
                self.assertFalse(self.run_download()["ok"])
                self.assertFalse((self.workspace / "artifacts.zip").exists())

    def test_should_refuse_unsafe_project_references_before_contacting_gitlab(self):
        for value in ("/ios/PhonePe", "ios//PhonePe", "ios/../PhonePe", "ios/./PhonePe", "ios/PhonePe/",
                      "ios%2FPhonePe", "https://gitlab.example.com/ios/PhonePe", "PhonePe;id", "PhonePe\n", " PhonePe", "x" * 1025):
            with self.subTest(value=value):
                self.request["args"]["projectId"] = value
                self.assertFalse(self.run_download()["ok"])
        self.assertEqual(self.calls, [])

    def test_should_publish_project_resolution_progress_before_downloading(self):
        with mock.patch.object(download, "atomic_json", wraps=download.atomic_json) as write:
            self.assert_prepared(self.run_download())
        phases = [call.args[1]["phase"] for call in write.call_args_list if call.args[0].name == "progress.json"]
        self.assertEqual(list(dict.fromkeys(phases)), ["resolving", "downloading", "extracting", "prepared"])

    def test_should_fail_closed_when_search_pagination_cannot_prove_uniqueness(self):
        self.request["args"]["projectId"] = "PhonePe"
        self.routes = {self.search("PhonePe", page): [self.project] * 100 for page in (1, 2)}
        with mock.patch.object(download, "SEARCH_PAGE_LIMIT", 2):
            result = self.run_download()
        self.assertFalse(result["ok"])
        self.assertIn("uniqueness could not be established", result["message"])
        self.assertEqual(len(self.calls), 2)

    def test_should_deduplicate_the_same_project_across_search_pages(self):
        self.request["args"]["projectId"] = "PhonePe"
        self.routes = {self.search("PhonePe"): [self.project] * 100, self.search("PhonePe", 2): [self.project]}
        self.assert_prepared(self.run_download())

    def test_should_refuse_invalid_search_pages_and_metadata_response_limits(self):
        self.request["args"]["projectId"] = "PhonePe"
        for value in ({"id": 301}, [self.project] * 101, [{"id": True}], b"x" * 257):
            with self.subTest(value=type(value)):
                self.routes = {self.search("PhonePe"): value}
                with mock.patch.object(download, "METADATA_LIMIT", 256 if isinstance(value, bytes) else download.METADATA_LIMIT):
                    result = self.run_download()
                self.assertFalse(result["ok"])
                self.assertFalse((self.workspace / "artifacts.zip").exists())

    def test_should_kill_and_reap_a_timed_out_project_lookup(self):
        process = mock.Mock()
        process.wait.side_effect = [subprocess.TimeoutExpired(["glab"], 30), -9]
        with mock.patch.object(download.subprocess, "Popen", return_value=process):
            result = download.run(self.request, self.config, self.env)
        self.assertFalse(result["ok"])
        self.assertIn("TimeoutExpired", result["message"])
        self.assertIn("30 seconds", result["message"])
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 2)

    def test_should_explain_a_missing_glab_during_project_resolution(self):
        with mock.patch.object(download.subprocess, "Popen", side_effect=FileNotFoundError(2, "No such file or directory", "glab")):
            result = download.run(self.request, self.config, self.env)
        self.assertFalse(result["ok"])
        self.assertIn("GitLab project resolution failed", result["message"])
        self.assertIn("FileNotFoundError", result["message"])
        self.assertIn("projects/ios%2FPhonePe", result["message"])

    def test_should_avoid_project_lookup_when_disk_space_is_insufficient(self):
        with mock.patch.object(download.shutil, "disk_usage", return_value=mock.Mock(free=0)):
            result = self.run_download()
        self.assertFalse(result["ok"])
        self.assertIn("Insufficient disk space for project lookup", result["message"])
        self.assertEqual(self.calls, [])

    def test_should_bound_real_metadata_output_at_the_operating_system_limit(self):
        spawn = subprocess.Popen
        def child(argv, **kwargs):
            return spawn([sys.executable, "-B", "-c", "import os; os.write(1, b'x' * 4096); os.write(1, b'x')"], **kwargs)
        with mock.patch.object(download, "METADATA_LIMIT", 128), mock.patch.object(download.subprocess, "Popen", side_effect=child):
            result = download.run(self.request, self.config, self.env)
        self.assertFalse(result["ok"])
        self.assertIn("limit: 128", result["message"])
        self.assertFalse((self.workspace / "artifacts.zip").exists())

    def test_should_resolve_a_path_and_prepare_its_artifact_through_a_real_glab_child(self):
        binary = self.workspace / "bin"
        binary.mkdir()
        executable = binary / "glab"
        executable.write_text(f"#!{sys.executable}\n" +
            "import json, os, sys\nfrom pathlib import Path\n" +
            "endpoint = sys.argv[-1]\n" +
            "with (Path(os.environ['BAGUETTE_RUN_DIR']) / 'calls.jsonl').open('a') as log:\n    log.write(json.dumps(sys.argv[1:]) + '\\n')\n" +
            f"if endpoint == 'projects/ios%2FPhonePe':\n    print({json.dumps(self.project)!r})\n" +
            f"elif endpoint == 'projects/301/jobs/456/artifacts':\n    sys.stdout.buffer.write({self.archive()!r})\n" +
            "else:\n    raise SystemExit(7)\n")
        executable.chmod(0o700)
        self.env["PATH"] = str(binary)
        result = download.run(self.request, self.config, self.env)
        self.assertTrue(result["ok"], result.get("message"))
        self.assertEqual((self.workspace / result["output"]["path"] / "MyApp").read_bytes(), b"executable")
        calls = [json.loads(line) for line in (self.workspace / "calls.jsonl").read_text().splitlines()]
        self.assertEqual([call[-1] for call in calls], ["projects/ios%2FPhonePe", "projects/301/jobs/456/artifacts"])


if __name__ == "__main__":
    unittest.main()
