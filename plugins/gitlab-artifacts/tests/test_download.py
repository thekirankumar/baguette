import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("gitlab_download", ROOT / "bin/download.py")
download = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(download)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "tests")
        self.addCleanup(self.temp.cleanup)
        self.workspace = Path(self.temp.name)
        self.env = {"BAGUETTE_RUN_DIR": str(self.workspace),
                    "GITLAB_HOST": "gitlab.example.com", "GITLAB_TOKEN": "secret-token"}
        self.config = {"host": "gitlab.example.com", "projectIds": [123],
                       "maxArchiveBytes": 1024 * 1024, "maxExpandedBytes": 1024 * 1024}
        self.request = {"version": 1, "command": "gitlab-artifacts:install", "udid": "simulator-id",
                        "workspace": str(self.workspace), "args": {"projectId": 123, "jobId": "456"}}

    def archive(self, entries=None, zip64=False):
        data = io.BytesIO()
        with warnings.catch_warnings(), zipfile.ZipFile(data, "w", zipfile.ZIP_DEFLATED) as archive:
            warnings.simplefilter("ignore", UserWarning)
            for name, content, mode in entries or [("build/MyApp.app/MyApp", b"executable", stat.S_IFREG | 0o755)]:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = mode << 16
                with archive.open(entry, "w", force_zip64=zip64) as file:
                    file.write(content)
        return data.getvalue()

    def run_download(self, data=None, code=0, running=False, stderr=b""):
        process = mock.Mock()
        process.poll.side_effect = [None, code] if running else [code]
        process.wait.return_value = code
        def spawn(argv, **kwargs):
            kwargs["stdout"].write(self.archive() if data is None else data)
            kwargs["stdout"].flush()
            if stderr:
                kwargs["stderr"].write(stderr)
                kwargs["stderr"].flush()
            return process
        with mock.patch.object(download.subprocess, "Popen", side_effect=spawn) as popen:
            result = download.run(self.request, self.config, self.env)
        return result, popen, process

    def assert_failure(self, result):
        self.assertFalse(result["ok"])
        self.assertIsInstance(result["message"], str)
        self.assertNotIn("secret-token", json.dumps(result))
        self.assertEqual(json.loads((self.workspace / "result.json").read_text()), result)

    def test_should_prepare_a_relative_simulator_app_and_preserve_executable_modes(self):
        result, popen, _ = self.run_download(running=True)
        self.assertEqual(result, {"ok": True, "output": {"kind": "simulator-app",
                         "path": "extracted/build/MyApp.app"}})
        app = self.workspace / result["output"]["path"]
        self.assertEqual((app / "MyApp").read_bytes(), b"executable")
        self.assertEqual(stat.S_IMODE((app / "MyApp").stat().st_mode), 0o755)
        self.assertEqual(json.loads((self.workspace / "result.json").read_text()), result)
        self.assertEqual(json.loads((self.workspace / "progress.json").read_text())["phase"], "prepared")
        self.assertEqual(popen.call_args.args[0], ["glab", "api", "--method", "GET",
                         "--hostname", "gitlab.example.com", "projects/123/jobs/456/artifacts"])
        kwargs = popen.call_args.kwargs
        self.assertEqual(kwargs["env"]["GITLAB_TOKEN"], "secret-token")
        self.assertNotIn("secret-token", str(popen.call_args.args))
        self.assertFalse(kwargs.get("shell", False))
        self.assertFalse(kwargs.get("start_new_session", False))
        self.assertNotIn("process_group", kwargs)
        self.assertNotEqual(kwargs["stderr"], download.subprocess.DEVNULL)

    def test_should_explain_a_missing_gitlab_executable(self):
        self.env["PATH"] = "/missing/bin"
        with mock.patch.object(download.subprocess, "Popen", side_effect=FileNotFoundError(2, "No such file or directory", "glab")):
            result = download.run(self.request, self.config, self.env)
        self.assert_failure(result)
        for detail in ("GitLab artifact download failed", "FileNotFoundError", "glab", "/missing/bin",
                       "projects/123/jobs/456/artifacts", "Traceback", str(self.workspace)):
            self.assertIn(detail, result["message"])

    def test_should_explain_an_executable_that_cannot_be_started(self):
        with mock.patch.object(download.subprocess, "Popen", side_effect=PermissionError(13, "Permission denied", "glab")):
            result = download.run(self.request, self.config, self.env)
        self.assert_failure(result)
        for detail in ("PermissionError", "Permission denied", "Command: glab", "glab stderr:"):
            self.assertIn(detail, result["message"])

    def test_should_explain_gitlab_rejections_with_stderr_and_exit_status(self):
        result, _, _ = self.run_download(code=1, stderr=b"glab: HTTP 403 Forbidden\nPermission denied for job 456\n")
        self.assert_failure(result)
        for detail in ("HTTP 403 Forbidden", "Permission denied for job 456", "exit status: 1",
                       "gitlab.example.com", "projects/123/jobs/456/artifacts", "downloaded bytes:"):
            self.assertIn(detail, result["message"])

    def test_should_explain_a_terminated_download_with_its_signal_and_size_limit(self):
        self.config["maxArchiveBytes"] = 8
        result, _, _ = self.run_download(data=b"x" * 8, code=-25)
        self.assert_failure(result)
        for detail in ("exit status: -25", "SIGXFSZ", "size limit: 8", "glab stderr:", "empty"):
            self.assertIn(detail, result["message"])

    def test_should_preserve_stderr_when_download_monitoring_fails(self):
        with mock.patch.object(download.time, "sleep", side_effect=OSError("monitoring failed")):
            result, _, process = self.run_download(running=True, stderr=b"TLS certificate verification failed")
        self.assert_failure(result)
        self.assertIn("OSError: monitoring failed", result["message"])
        self.assertIn("TLS certificate verification failed", result["message"])
        process.kill.assert_called_once()
        process.wait.assert_called_once()

    def test_should_redact_credentials_without_hiding_gitlab_diagnostics(self):
        self.env["OTHER_PASSWORD"] = "private-password"
        result, _, _ = self.run_download(code=1, stderr=(
            b"HTTP 401 Unauthorized secret-token private-password\n"
            b"Authorization: Bearer unknown-bearer\nPRIVATE-TOKEN: unknown-private\n"
            b"https://user:url-password@gitlab.example.com/api?private_token=query-token\n"))
        self.assert_failure(result)
        for secret in ("private-password", "unknown-bearer", "unknown-private", "url-password", "query-token"):
            self.assertNotIn(secret, result["message"])
        self.assertIn("HTTP 401 Unauthorized", result["message"])
        self.assertIn("[REDACTED]", result["message"])

    def test_should_explain_disk_and_archive_limits_with_actual_values(self):
        with mock.patch.object(download.shutil, "disk_usage", return_value=mock.Mock(free=17)):
            result, _, _ = self.run_download()
        self.assert_failure(result)
        for detail in ("Insufficient disk space", "17", str(self.config["maxArchiveBytes"]), str(download.DISK_RESERVE)):
            self.assertIn(detail, result["message"])

    def test_should_name_ambiguous_simulator_apps(self):
        result, _, _ = self.run_download(data=self.archive([
            (name, b"x", stat.S_IFREG) for name in ("One.app/file", "build/Two.app/file")]))
        self.assert_failure(result)
        for detail in ("One.app", "build/Two.app", "found 2"):
            self.assertIn(detail, result["message"])

    def test_should_explain_failures_from_a_real_child_without_stderr_pipe_deadlock(self):
        spawn = subprocess.Popen
        def child(argv, **kwargs):
            return spawn([sys.executable, "-B", "-c",
                          "import os; os.write(2, b'x' * 100000 + b' HTTP 404 artifact expired'); raise SystemExit(7)"], **kwargs)
        with mock.patch.object(download.subprocess, "Popen", side_effect=child):
            result = download.run(self.request, self.config, self.env)
        self.assert_failure(result)
        self.assertIn("HTTP 404 artifact expired", result["message"])
        self.assertIn("exit status: 7", result["message"])

    def test_should_fit_verbose_unicode_diagnostics_into_the_unchanged_host_limit(self):
        result, _, _ = self.run_download(code=1, stderr=("HTTP 403 start " + "🚀" * 20000 + " artifact expired").encode())
        self.assert_failure(result)
        self.assertLessEqual(len(result["message"].encode()), 4096)
        self.assertLessEqual((self.workspace / "result.json").stat().st_size, 65536)
        for detail in ("HTTP 403 start", "artifact expired", "truncated", "exit status: 1", "Command: glab"):
            self.assertIn(detail, result["message"])
        self.assertNotIn("\ufffd", result["message"])

    def test_should_explain_invalid_archive_entries_with_the_offending_path(self):
        result, _, _ = self.run_download(data=self.archive([("../escape", b"x", stat.S_IFREG)]))
        self.assert_failure(result)
        self.assertIn("../escape", result["message"])

    def test_should_explain_missing_glab_from_the_real_script(self):
        self.env["PATH"] = str(self.workspace / "missing-bin")
        plugin = self.workspace / "plugin"
        (plugin / "bin").mkdir(parents=True)
        shutil.copyfile(ROOT / "bin/download.py", plugin / "bin/download.py")
        (plugin / "config.json").write_text(json.dumps(self.config))
        completed = subprocess.run([sys.executable, "-B", str(plugin / "bin/download.py")],
                                   input=json.dumps(self.request), text=True, capture_output=True,
                                   env=self.env, timeout=10)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr, "")
        result = json.loads((self.workspace / "result.json").read_text())
        self.assert_failure(result)
        self.assertIn("FileNotFoundError", result["message"])
        self.assertIn("glab", result["message"])
        self.assertIn(self.env["PATH"], result["message"])

    def test_should_report_each_progress_phase(self):
        with mock.patch.object(download, "atomic_json", wraps=download.atomic_json) as write:
            self.run_download(running=True)
        progress = [call.args[1] for call in write.call_args_list if call.args[0].name == "progress.json"]
        self.assertEqual(list(dict.fromkeys(item["phase"] for item in progress)),
                         ["downloading", "extracting", "prepared"])
        self.assertTrue(any(item.get("downloadedBytes", 0) > 0 for item in progress))

    def test_should_preserve_the_supplied_home_for_the_gitlab_download(self):
        self.env["HOME"] = str(self.workspace)
        result, popen, _ = self.run_download()
        self.assertTrue(result["ok"])
        self.assertEqual(popen.call_args.kwargs["env"]["HOME"], str(self.workspace))

    def test_should_refuse_unapproved_projects_and_argument_overrides(self):
        invalid = [{"projectId": 999, "jobId": 1}, {"projectId": 123, "jobId": 1, "token": "x"},
                   {"projectId": 123, "jobId": 1, "path": "x"},
                   {"projectId": 123, "jobId": 1, "url": "https://evil.test"}]
        for args in invalid:
            with self.subTest(args=args), mock.patch.object(download.subprocess, "Popen") as popen:
                self.request["args"] = args
                self.assert_failure(download.run(self.request, self.config, self.env))
                popen.assert_not_called()

    def test_should_refuse_non_positive_or_non_integer_identifiers(self):
        for field in ("projectId", "jobId"):
            for value in (0, -1, True, 1.0, None, "", "01", "+1", " 1", "1/2", "https://x", "1;id"):
                with self.subTest(field=field, value=value):
                    self.request["args"] = {"projectId": 123, "jobId": 456, field: value}
                    result, popen, _ = self.run_download()
                    self.assert_failure(result)
                    popen.assert_not_called()

    def test_should_refuse_missing_credentials_or_a_different_host(self):
        for field, value in (("GITLAB_TOKEN", ""), ("GITLAB_HOST", "evil.test"), ("GITLAB_HOST", "")):
            with self.subTest(field=field, value=value):
                env = dict(self.env, **{field: value})
                with mock.patch.object(download.subprocess, "Popen") as popen:
                    self.assert_failure(download.run(self.request, self.config, env))
                    popen.assert_not_called()

    def test_should_refuse_invalid_envelopes(self):
        for field, value in (("version", True), ("version", 2), ("command", "other"),
                             ("udid", ""), ("workspace", str(self.workspace / "other")), ("args", [])):
            with self.subTest(field=field):
                request = dict(self.request, **{field: value})
                with mock.patch.object(download.subprocess, "Popen") as popen:
                    self.assert_failure(download.run(request, self.config, self.env))
                    popen.assert_not_called()

    def test_should_refuse_invalid_configuration(self):
        for change in ({"host": "https://gitlab.example.com"}, {"host": "x/path"},
                       {"projectIds": [True]}, {"projectIds": ["123"]}, {"projectIds": []},
                       {"maxArchiveBytes": 0}, {"maxExpandedBytes": True},
                       {"appPath": "../MyApp.app"}, {"appPath": "/MyApp.app"}):
            with self.subTest(change=change):
                config = dict(self.config, **change)
                with mock.patch.object(download.subprocess, "Popen") as popen:
                    self.assert_failure(download.run(self.request, config, self.env))
                    popen.assert_not_called()

    def test_should_fail_safely_when_gitlab_rejects_the_download(self):
        result, _, _ = self.run_download(data=b"HTTP 403 secret-token", code=1)
        self.assert_failure(result)
        self.assertFalse((self.workspace / "extracted").exists())

    def test_should_stop_an_oversized_download_while_it_is_running(self):
        self.config["maxArchiveBytes"] = 8
        result, _, process = self.run_download(data=b"x" * 9, running=True)
        self.assert_failure(result)
        process.kill.assert_called_once()
        process.wait.assert_called_once()

    def test_should_refuse_an_oversized_completed_download(self):
        self.config["maxArchiveBytes"] = 8
        self.assert_failure(self.run_download(data=b"x" * 9)[0])

    def test_should_refuse_downloads_when_disk_space_is_low(self):
        with mock.patch.object(download.shutil, "disk_usage", return_value=mock.Mock(free=0)):
            result, popen, _ = self.run_download()
        self.assert_failure(result)
        popen.assert_not_called()

    def test_should_refuse_unsafe_zip_paths_and_special_files_before_extraction(self):
        for name, mode in (("../escape", stat.S_IFREG), ("/escape", stat.S_IFREG),
                           ("C:/escape", stat.S_IFREG), ("a\\escape", stat.S_IFREG),
                           ("a/./escape", stat.S_IFREG), ("a//escape", stat.S_IFREG),
                           ("link", stat.S_IFLNK), ("fifo", stat.S_IFIFO),
                           ("device", stat.S_IFCHR), ("socket", stat.S_IFSOCK)):
            with self.subTest(name=name, mode=mode):
                data = self.archive([("MyApp.app/file", b"ok", stat.S_IFREG | 0o644), (name, b"x", mode | 0o777)])
                self.assert_failure(self.run_download(data=data)[0])
                self.assertFalse((self.workspace / "extracted").exists())

    def test_should_refuse_duplicate_and_conflicting_zip_paths(self):
        for names in (("a", "a"), ("A", "a"), ("a", "a/b"), ("a/b", "a"),
                      ("A/b", "a/c"), ("caf\u00e9", "cafe\u0301")):
            with self.subTest(names=names):
                self.assert_failure(self.run_download(data=self.archive([
                    (name, b"x", stat.S_IFREG | 0o644) for name in names]))[0])
                self.assertFalse((self.workspace / "extracted").exists())

    def test_should_enforce_single_entry_and_cumulative_expanded_limits(self):
        self.config["maxExpandedBytes"] = 10
        for entries in ([ ("MyApp.app/file", b"x" * 11, stat.S_IFREG)],
                        [("MyApp.app/a", b"x" * 6, stat.S_IFREG), ("MyApp.app/b", b"x" * 5, stat.S_IFREG)]):
            with self.subTest(entries=entries):
                self.assert_failure(self.run_download(data=self.archive(entries))[0])
                self.assertFalse((self.workspace / "extracted").exists())

    def test_should_check_free_space_before_extraction(self):
        with mock.patch.object(download.shutil, "disk_usage", side_effect=[mock.Mock(free=10**9), mock.Mock(free=0)]):
            self.assert_failure(self.run_download()[0])
        self.assertFalse((self.workspace / "extracted").exists())

    def test_should_enforce_actual_expanded_bytes_even_when_zip_metadata_understates_them(self):
        self.config["maxExpandedBytes"] = 4
        data = self.archive([("MyApp.app/file", b"x", stat.S_IFREG | 0o644)])
        with mock.patch.object(download.zipfile.ZipFile, "open", return_value=io.BytesIO(b"x" * 5)):
            self.assert_failure(self.run_download(data=data)[0])
        self.assertEqual((self.workspace / "extracted/MyApp.app/file").stat().st_size, 0)

    def test_should_refuse_truncated_expansion_and_corrupt_crc(self):
        data = self.archive([("MyApp.app/file", b"content", stat.S_IFREG | 0o644)])
        with mock.patch.object(download.zipfile.ZipFile, "open", return_value=io.BytesIO(b"x")):
            self.assert_failure(self.run_download(data=data)[0])
        shutil.rmtree(self.workspace / "extracted")
        corrupt = data.replace(b"content", b"corrupt", 1)
        self.assert_failure(self.run_download(data=corrupt)[0])

    def test_should_preserve_directory_modes_and_accept_explicit_parents_after_children(self):
        data = self.archive([("MyApp.app/file", b"x", stat.S_IFREG | 0o644),
                             ("MyApp.app/", b"", stat.S_IFDIR | 0o750)])
        result, _, _ = self.run_download(data=data)
        self.assertTrue(result["ok"])
        self.assertEqual(stat.S_IMODE((self.workspace / result["output"]["path"]).stat().st_mode), 0o750)

    def test_should_stop_downloading_when_remaining_disk_space_is_low(self):
        with mock.patch.object(download.shutil, "disk_usage", side_effect=[mock.Mock(free=10**9), mock.Mock(free=0)]):
            result, _, process = self.run_download(running=True)
        self.assert_failure(result)
        process.kill.assert_called_once()

    def test_should_stop_the_child_when_download_monitoring_fails(self):
        with mock.patch.object(download.time, "sleep", side_effect=OSError("secret-token")):
            result, _, process = self.run_download(running=True)
        self.assert_failure(result)
        process.kill.assert_called_once()
        process.wait.assert_called_once()

    def test_should_reap_the_child_when_polling_fails(self):
        process = mock.Mock()
        process.poll.side_effect = OSError("secret-token")
        with mock.patch.object(download.subprocess, "Popen", return_value=process):
            self.assert_failure(download.run(self.request, self.config, self.env))
        process.kill.assert_called_once()
        process.wait.assert_called_once()

    def test_should_stream_a_real_child_into_the_archive_without_buffering_it(self):
        data = self.archive()
        spawn = subprocess.Popen
        def child(argv, **kwargs):
            return spawn([sys.executable, "-B", "-c", "import os; os.write(1, " + repr(data) + ")"], **kwargs)
        with mock.patch.object(download.subprocess, "Popen", side_effect=child):
            self.assertTrue(download.run(self.request, self.config, self.env)["ok"])

    def test_should_bound_real_child_download_bytes_at_the_operating_system_limit(self):
        self.config["maxArchiveBytes"] = 8
        spawn = subprocess.Popen
        def child(argv, **kwargs):
            return spawn([sys.executable, "-B", "-c", "import os; os.write(1, b'x' * 4096); os.write(1, b'x')"], **kwargs)
        with mock.patch.object(download.subprocess, "Popen", side_effect=child):
            self.assert_failure(download.run(self.request, self.config, self.env))
        self.assertLessEqual((self.workspace / "artifacts.zip").stat().st_size, 8)

    def test_should_use_default_archive_and_expansion_limits(self):
        self.config.pop("maxArchiveBytes")
        self.config.pop("maxExpandedBytes")
        with mock.patch.object(download.shutil, "disk_usage", return_value=mock.Mock(free=32 * 1024**3)):
            result, popen, _ = self.run_download()
        self.assertTrue(result["ok"])
        with mock.patch.object(download.resource, "setrlimit") as cap:
            popen.call_args.kwargs["preexec_fn"]()
        cap.assert_called_once_with(download.resource.RLIMIT_FSIZE, (3 * 1024**3, 3 * 1024**3))

    def test_should_accept_zip64_archives(self):
        self.assertTrue(self.run_download(data=self.archive(zip64=True))[0]["ok"])

    def test_should_ignore_nested_app_bundles(self):
        data = self.archive([(name, b"x", stat.S_IFREG | 0o644) for name in (
            "build/MyApp.app/file", "build/MyApp.app/Watch/Watch.app/file",
            "Other.bundle/Nested.app/file", "Other.framework/Nested.app/file")])
        self.assertEqual(self.run_download(data=data)[0]["output"]["path"], "extracted/build/MyApp.app")

    def test_should_refuse_missing_or_ambiguous_apps(self):
        for names in (("file",), ("One.app/file", "Two.app/file"), ("Fake.app",)):
            with self.subTest(names=names):
                data = self.archive([(name, b"x", stat.S_IFREG) for name in names])
                self.assert_failure(self.run_download(data=data)[0])
                # Each run has its own private extraction directory.
                if (self.workspace / "extracted").exists():
                    shutil.rmtree(self.workspace / "extracted")

    def test_should_select_only_the_host_configured_app_path(self):
        self.config["appPath"] = "build/Two.app"
        data = self.archive([(name, b"x", stat.S_IFREG) for name in ("One.app/file", "build/Two.app/file")])
        self.assertEqual(self.run_download(data=data)[0]["output"]["path"], "extracted/build/Two.app")

    def test_should_refuse_a_missing_host_configured_app(self):
        self.config["appPath"] = "Missing.app"
        self.assert_failure(self.run_download()[0])

    def test_should_fail_safely_for_corrupt_archives_and_unexpected_errors(self):
        self.assert_failure(self.run_download(data=b"not zip secret-token")[0])
        with mock.patch.object(download.subprocess, "Popen", side_effect=OSError("secret-token")):
            self.assert_failure(download.run(self.request, self.config, self.env))

    def test_should_publish_json_with_atomic_replacement_and_private_permissions(self):
        target = self.workspace / "result.json"
        with mock.patch.object(download.os, "replace", wraps=os.replace) as replace:
            download.atomic_json(target, {"ok": False, "message": "safe failure"})
        self.assertEqual(replace.call_args.args[1], target)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual(list(self.workspace.iterdir()), [target])

    def test_should_read_stdin_and_fixed_plugin_configuration_without_stdout_json(self):
        with mock.patch.object(download.sys, "stdin", io.StringIO(json.dumps(self.request))), \
             mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(download, "load_config", return_value=self.config) as load, \
             mock.patch.object(download, "run", return_value={"ok": True}) as run, \
             contextlib.redirect_stdout(io.StringIO()) as stdout:
            self.assertEqual(download.main(), 0)
        load.assert_called_once_with(ROOT / "config.json")
        self.assertEqual(run.call_args.args[0], self.request)
        self.assertEqual(stdout.getvalue(), "")

    def test_should_publish_safe_failure_for_malformed_stdin(self):
        with mock.patch.object(download.sys, "stdin", io.StringIO("not JSON secret-token")), \
             mock.patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(download.main(), 0)
        self.assert_failure(json.loads((self.workspace / "result.json").read_text()))

    def test_should_ship_the_approved_background_manifest_and_allow_all_projects_on_the_configured_host(self):
        manifest = json.loads((ROOT / "baguette-plugin.json").read_text())
        self.assertEqual(manifest["capabilities"], ["apps"])
        self.assertEqual(manifest["contributes"]["commands"], [{"id": "install", "title": "Install GitLab artifact",
                         "run": ["python3", "bin/download.py"], "background": {"timeoutSeconds": 3600,
                         "environment": ["GITLAB_TOKEN", "GITLAB_HOST", "HOME"]}}])
        config = json.loads((ROOT / "config.json").read_text())
        self.assertEqual(config["host"], "gitlab.phonepe.com")
        self.assertEqual(config["projectIds"], "*")
        self.assertEqual(config["maxArchiveBytes"], 3 * 1024**3)
        self.assertEqual(config["maxExpandedBytes"], 16 * 1024**3)
        self.assertEqual(config["maxEntries"], 50000)

    def test_should_prepare_apps_from_any_positive_project_when_explicitly_allowed(self):
        self.config["projectIds"] = "*"
        for project in (1, 301, "987654321"):
            with self.subTest(project=project):
                self.request["args"]["projectId"] = project
                result, popen, _ = self.run_download()
                self.assertTrue(result["ok"])
                self.assertEqual(popen.call_args.args[0][-1], f"projects/{project}/jobs/456/artifacts")
                if (self.workspace / "extracted").exists():
                    shutil.rmtree(self.workspace / "extracted")

    def test_should_refuse_arbitrary_project_allowlist_values_before_downloading(self):
        for projects in ("all", "123", "", " *", "* ", None, True, 123, 1.5, {}, ["*"], [123, "*"], [0], [-1]):
            with self.subTest(projects=projects):
                self.config["projectIds"] = projects
                result, popen, _ = self.run_download()
                self.assert_failure(result)
                self.assertIn("Invalid artifact request or host configuration", result["message"])
                popen.assert_not_called()

    def test_should_keep_identifiers_and_host_restricted_when_all_projects_are_allowed(self):
        self.config["projectIds"] = "*"
        for project in (0, -1, True, "*", "https://evil.test", "1;id"):
            with self.subTest(project=project):
                self.request["args"]["projectId"] = project
                result, popen, _ = self.run_download()
                self.assert_failure(result)
                popen.assert_not_called()
        self.request["args"]["projectId"] = 301
        self.env["GITLAB_HOST"] = "evil.test"
        result, popen, _ = self.run_download()
        self.assert_failure(result)
        popen.assert_not_called()

    def test_should_reject_unqualified_commands_before_downloading(self):
        self.request["command"] = "install"
        result, popen, _ = self.run_download()
        self.assert_failure(result)
        self.assertIn("Invalid artifact request or host configuration", result["message"])
        popen.assert_not_called()

    def test_should_explain_each_failure_stage_without_exposing_credentials(self):
        stages = [("policy", "Invalid artifact request or host configuration"),
                  ("download_archive", "GitLab artifact download failed. Check credentials, job artifacts, download limits, and disk space."),
                  ("extract_archive", "Artifact extraction failed. Check archive contents, extraction limits, and disk space."),
                  ("select_app", "No unique simulator app found. Configure appPath or provide exactly one top-level app.")]
        for function, message in stages:
            with self.subTest(function=function), \
                 mock.patch.object(download, function, side_effect=ValueError("secret-token " + str(self.workspace))):
                result = self.run_download()[0]
                self.assert_failure(result)
                self.assertIn(message, result["message"])
                self.assertIn("ValueError:", result["message"])
                self.assertIn("Traceback", result["message"])
            if (self.workspace / "extracted").exists():
                shutil.rmtree(self.workspace / "extracted")

    def test_should_exit_zero_for_a_published_structured_failure(self):
        with mock.patch.object(download.sys, "stdin", io.StringIO(json.dumps(self.request))), \
             mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(download, "load_config", return_value=self.config), \
             mock.patch.object(download.subprocess, "Popen", side_effect=OSError("secret-token")):
            self.assertEqual(download.main(), 0)
        self.assert_failure(json.loads((self.workspace / "result.json").read_text()))

    def test_should_exit_nonzero_when_no_result_can_be_published(self):
        with mock.patch.object(download.sys, "stdin", io.StringIO("not JSON")), \
             mock.patch.dict(os.environ, {}, clear=True), \
             contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(download.main(), 1)
        self.assertIn("JSONDecodeError", stderr.getvalue())
        self.assertFalse((self.workspace / "result.json").exists())

    def test_should_exit_nonzero_when_result_publication_is_unwritable(self):
        with mock.patch.object(download.sys, "stdin", io.StringIO(json.dumps(self.request))), \
             mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(download, "load_config", return_value=self.config), \
             mock.patch.object(download, "atomic_json", side_effect=OSError("secret-token")), \
             mock.patch.object(download.subprocess, "Popen") as popen, \
             contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(download.main(), 1)
        self.assertIn("OSError", stderr.getvalue())
        self.assertNotIn("secret-token", stderr.getvalue())
        self.assertFalse((self.workspace / "result.json").exists())
        popen.assert_not_called()

    def test_should_convey_missing_credentials_from_the_real_qualified_script(self):
        plugin = self.workspace / "plugin"
        (plugin / "bin").mkdir(parents=True)
        shutil.copyfile(ROOT / "bin/download.py", plugin / "bin/download.py")
        (plugin / "config.json").write_text(json.dumps(self.config))
        for missing in ("GITLAB_TOKEN", "GITLAB_HOST"):
            with self.subTest(missing=missing):
                env = {key: value for key, value in self.env.items() if key != missing}
                completed = subprocess.run([sys.executable, "-B", str(plugin / "bin/download.py")],
                                           input=json.dumps(self.request), text=True, capture_output=True,
                                           env=env, timeout=10)
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(completed.stdout, "")
                self.assertEqual(completed.stderr, "")
                result = json.loads((self.workspace / "result.json").read_text())
                self.assert_failure(result)
                self.assertIn(missing, result["message"])
                self.assertFalse((self.workspace / "artifacts.zip").exists())
        (plugin / "config.json").unlink()
        completed = subprocess.run([sys.executable, "-B", str(plugin / "bin/download.py")],
                                   input=json.dumps(self.request), text=True, capture_output=True,
                                   env=self.env, timeout=10)
        self.assertEqual(completed.returncode, 0)
        result = json.loads((self.workspace / "result.json").read_text())
        self.assert_failure(result)
        self.assertIn("FileNotFoundError", result["message"])
        self.assertIn("config.json", result["message"])

    def test_should_refuse_excessive_zip_entries_before_extraction(self):
        self.config["maxEntries"] = 1
        data = self.archive([("MyApp.app/a", b"", stat.S_IFREG), ("MyApp.app/b", b"", stat.S_IFREG)])
        result, _, _ = self.run_download(data=data)
        self.assert_failure(result)
        self.assertTrue(result["message"].startswith("Artifact extraction failed"))
        self.assertFalse((self.workspace / "extracted").exists())

    def test_should_accept_the_configured_zip_entry_count_boundary(self):
        self.config["maxEntries"] = 1
        self.assertTrue(self.run_download()[0]["ok"])

    def test_should_refuse_more_than_50000_entries_by_default(self):
        with mock.patch.object(download.zipfile.ZipFile, "infolist", return_value=[mock.Mock()] * 50001):
            result, _, _ = self.run_download()
        self.assert_failure(result)
        self.assertTrue(result["message"].startswith("Artifact extraction failed"))
        self.assertFalse((self.workspace / "extracted").exists())

    def test_should_validate_entry_limits_before_downloading(self):
        for limit in (0, -1, True, "50000", 1.5):
            with self.subTest(limit=limit):
                self.config["maxEntries"] = limit
                result, popen, _ = self.run_download()
                self.assert_failure(result)
                self.assertIn("Invalid artifact request or host configuration", result["message"])
                popen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
