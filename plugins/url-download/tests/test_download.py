import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
SPEC = importlib.util.spec_from_file_location("url_download", ROOT / "bin/download.py")
download = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(download)


class DownloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=ROOT / "tests")
        self.addCleanup(temporary.cleanup)
        self.workspace = Path(temporary.name)
        self.seen = []
        self.routes = {}
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                owner.seen.append((self.path, dict(self.headers)))
                status, headers, body = owner.routes.get(self.path, (404, {}, b"artifact missing"))
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True)
        thread.start()
        def stop():
            self.server.shutdown()
            self.server.server_close()
            thread.join(timeout=5)
        self.addCleanup(stop)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.env = {"BAGUETTE_RUN_DIR": str(self.workspace), "BAGUETTE_TOKEN": "host-secret"}
        self.config = {"allowedHosts": ["127.0.0.1"], "allowHTTP": True,
                       "maxArchiveBytes": 1024 * 1024, "maxExpandedBytes": 1024 * 1024,
                       "maxEntries": 100, "requestTimeoutSeconds": 2, "maxRedirects": 5}
        self.request = {"version": 1, "command": "url-download:install", "udid": "simulator-id",
                        "workspace": str(self.workspace), "args": {"url": self.base + "/app.zip"}}
        self.route("/app.zip", self.archive())

    def archive(self, names=None):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w", zipfile.ZIP_DEFLATED) as archive:
            for name in names or ["build/MyApp.app/MyApp"]:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | 0o755) << 16
                archive.writestr(entry, b"executable")
        return data.getvalue()

    def route(self, path, body=b"", status=200, headers=None):
        self.routes[path] = (status, {"Content-Length": str(len(body)), **(headers or {})}, body)

    def run_download(self):
        result = download.run(self.request, self.config, self.env)
        self.assertEqual(json.loads((self.workspace / "result.json").read_text()), result)
        return result

    def assert_failure(self, result, *details):
        self.assertFalse(result["ok"])
        self.assertLessEqual(len(result["message"].encode()), 4096)
        self.assertLessEqual((self.workspace / "result.json").stat().st_size, 65536)
        self.assertNotIn("host-secret", json.dumps(result))
        for detail in details:
            self.assertIn(detail, result["message"])

    def test_should_prepare_a_zipped_app_and_preserve_executable_permissions(self):
        result = self.run_download()
        self.assertEqual(result, {"ok": True, "output": {"kind": "simulator-app", "path": "extracted/build/MyApp.app"}})
        binary = self.workspace / result["output"]["path"] / "MyApp"
        self.assertEqual(binary.read_bytes(), b"executable")
        self.assertEqual(stat.S_IMODE(binary.stat().st_mode), 0o755)

    def test_should_send_authorization_and_custom_headers_from_invocation_parameters(self):
        self.request["args"]["headers"] = {"Authorization": "Bearer invocation-secret", "X-API-Key": "custom-secret"}
        self.assertTrue(self.run_download()["ok"])
        headers = {key.lower(): value for key, value in self.seen[0][1].items()}
        self.assertEqual(headers["authorization"], "Bearer invocation-secret")
        self.assertEqual(headers["x-api-key"], "custom-secret")
        self.assertNotIn("host-secret", str(headers))

    def test_should_hand_an_ipa_to_the_host_without_extracting_it(self):
        self.request["args"]["url"] = self.base + "/Build.IPA"
        data = self.archive(["Payload/MyApp.app/Info.plist", "Payload/MyApp.app/MyApp"])
        self.route("/Build.IPA", data)
        result = self.run_download()
        self.assertEqual(result, {"ok": True, "output": {"kind": "simulator-app", "path": "download.ipa"}})
        self.assertEqual((self.workspace / "download.ipa").read_bytes(), data)
        self.assertFalse((self.workspace / "extracted").exists())

    def test_should_recognize_an_ipa_from_response_filename_or_archive_layout(self):
        for headers in ({"Content-Disposition": 'attachment; filename="Build.ipa"'}, {}):
            with self.subTest(headers=headers):
                self.request["args"]["url"] = self.base + "/opaque"
                self.route("/opaque", self.archive(["Payload/MyApp.app/Info.plist"]), headers=headers)
                self.assertEqual(self.run_download()["output"]["path"], "download.ipa")

    def test_should_recognize_an_extensionless_zip_by_its_contents(self):
        self.request["args"]["url"] = self.base + "/opaque"
        self.route("/opaque", self.archive(), headers={"Content-Type": "application/octet-stream"})
        self.assertEqual(self.run_download()["output"]["path"], "extracted/build/MyApp.app")

    def test_should_keep_an_explicit_zip_with_payload_as_a_zip(self):
        self.route("/app.zip", self.archive(["Payload/MyApp.app/Info.plist"]))
        self.assertEqual(self.run_download()["output"]["path"], "extracted/Payload/MyApp.app")

    def test_should_report_download_extraction_and_prepared_progress(self):
        with mock.patch.object(download.artifact, "atomic_json", wraps=download.artifact.atomic_json) as write:
            self.assertTrue(self.run_download()["ok"])
        progress = [call.args[1] for call in write.call_args_list if call.args[0].name == "progress.json"]
        self.assertEqual(list(dict.fromkeys(item["phase"] for item in progress)), ["downloading", "extracting", "prepared"])
        self.assertTrue(any(item.get("downloadedBytes", 0) > 0 for item in progress))

    def test_should_report_available_download_bytes_without_waiting_for_a_full_megabyte(self):
        response = mock.Mock()
        data = self.archive()
        response.status = 200
        response.headers = {"Content-Length": str(len(data))}
        response.read.side_effect = AssertionError("must not wait to fill the whole read buffer")
        response.read1.side_effect = [data[:10], data[10:], b""]
        with mock.patch.object(download, "open_response", return_value=response), \
             mock.patch.object(download.artifact, "atomic_json", wraps=download.artifact.atomic_json) as write:
            self.assertTrue(self.run_download()["ok"])
        progress = [call.args[1] for call in write.call_args_list if call.args[0].name == "progress.json"]
        self.assertIn({"phase": "downloading", "downloadedBytes": 10}, progress)

    def test_should_validate_ipa_integrity_before_direct_handoff_without_extracting(self):
        self.request["args"]["url"] = self.base + "/build.ipa"
        data = self.archive(["Payload/MyApp.app/Info.plist"])
        self.route("/build.ipa", data.replace(b"executable", b"corruption", 1))
        self.assert_failure(self.run_download(), "CRC")
        self.assertFalse((self.workspace / "extracted").exists())
        self.assertFalse((self.workspace / "download.ipa").exists())

    def test_should_explain_http_errors_without_exposing_headers_or_signed_queries(self):
        self.request["args"].update(url=self.base + "/denied?signature=signed-secret", headers={
            "Authorization": "Bearer auth-secret", "X-Custom": "custom-secret"})
        self.route("/denied?signature=signed-secret",
                   b"Forbidden: signed-secret auth-secret custom-secret host-secret", status=403)
        result = self.run_download()
        self.assert_failure(result, "403", "Forbidden", "Causes:", "Traceback", "[REDACTED]")
        for secret in ("signed-secret", "auth-secret", "custom-secret"):
            self.assertNotIn(secret, result["message"])

    def test_should_keep_diagnostics_within_the_host_limit_and_mark_truncation(self):
        self.route("/app.zip", ("start of error " + "🚀" * 20000 + " end of error").encode(), status=500)
        self.assert_failure(self.run_download(), "500", "start of error", "truncated")

    def test_should_redact_raw_and_decoded_query_secrets_in_error_bodies(self):
        self.request["args"]["url"] = self.base + "/denied?signature=encoded%2Fsecret%3D"
        self.route("/denied?signature=encoded%2Fsecret%3D", b"rejected encoded%2Fsecret%3D and encoded/secret=", status=403)
        result = self.run_download()
        self.assert_failure(result, "403", "rejected")
        self.assertNotIn("encoded%2Fsecret%3D", result["message"])
        self.assertNotIn("encoded/secret=", result["message"])

    def test_should_explain_network_and_tls_failures(self):
        for error in (download.urllib.error.URLError("certificate verify failed"), socket.timeout("read timed out")):
            with self.subTest(error=error), mock.patch.object(download, "open_response", side_effect=error):
                self.assert_failure(self.run_download(), str(error))

    def test_should_refuse_unapproved_hosts_and_non_http_urls_before_connecting(self):
        for url in ("https://unapproved.example/app.zip", "file:///etc/passwd", "ftp://127.0.0.1/app.zip",
                    "http://user:password@127.0.0.1/app.zip", self.base + "/a\r\nInjected: yes"):
            with self.subTest(url=url), mock.patch.object(download, "open_response") as open_response:
                self.request["args"]["url"] = url
                self.assert_failure(self.run_download())
                open_response.assert_not_called()

    def test_should_require_explicit_host_policy_and_http_opt_in(self):
        for change in ({"allowedHosts": []}, {"allowHTTP": False}, {"allowedHosts": "all"}):
            with self.subTest(change=change), mock.patch.object(download, "open_response") as open_response:
                self.assert_failure(download.run(self.request, dict(self.config, **change), self.env))
                open_response.assert_not_called()

    def test_should_reject_header_injection_and_transport_header_overrides(self):
        for headers in ([], {"Authorization": 1}, {"Bad\r\nName": "x"}, {"Authorization": "x\r\nInjected: yes"},
                        {"Host": "evil.example"}, {"Content-Length": "3"}, {"Transfer-Encoding": "chunked"}):
            with self.subTest(headers=headers), mock.patch.object(download, "open_response") as open_response:
                self.request["args"]["headers"] = headers
                self.assert_failure(self.run_download())
                open_response.assert_not_called()

    def test_should_preserve_headers_on_same_origin_redirects(self):
        self.request["args"]["headers"] = {"Authorization": "Bearer auth-secret"}
        self.route("/app.zip", status=302, headers={"Location": "/final.zip"})
        self.route("/final.zip", self.archive())
        self.assertTrue(self.run_download()["ok"])
        self.assertEqual(self.seen[-1][1]["Authorization"], "Bearer auth-secret")

    def test_should_drop_all_custom_headers_when_a_redirect_changes_origin(self):
        self.request["args"]["headers"] = {"Authorization": "Bearer auth-secret", "X-Custom": "custom-secret"}
        self.config["allowedHosts"].append("localhost")
        self.route("/app.zip", status=302, headers={"Location": f"http://localhost:{self.server.server_port}/final.zip"})
        self.route("/final.zip", self.archive())
        self.assertTrue(self.run_download()["ok"])
        headers = {key.lower(): value for key, value in self.seen[-1][1].items()}
        self.assertNotIn("authorization", headers)
        self.assertNotIn("x-custom", headers)

    def test_should_refuse_redirects_to_unapproved_hosts_and_redirect_loops(self):
        for target in ("https://unapproved.example/file.zip", "/app.zip"):
            with self.subTest(target=target):
                self.route("/app.zip", status=302, headers={"Location": target})
                self.assert_failure(self.run_download(), "redirect")

    def test_should_refuse_https_downgrades_even_when_http_is_enabled(self):
        self.request["args"]["url"] = "https://127.0.0.1/app.zip"
        response = mock.MagicMock()
        response.status = 302
        response.headers = {"Location": self.base + "/final.zip"}
        with mock.patch.object(download, "open_response", return_value=response):
            self.assert_failure(self.run_download(), "HTTPS", "HTTP")

    def test_should_enforce_download_size_with_and_without_content_length(self):
        self.config["maxArchiveBytes"] = 8
        for length in ("100", None):
            with self.subTest(length=length):
                self.routes["/app.zip"] = (200, {} if length is None else {"Content-Length": length}, b"x" * 100)
                self.assert_failure(self.run_download(), "limit", "8")
                self.assertLessEqual((self.workspace / "download.bin").stat().st_size, 8)

    def test_should_explain_a_truncated_response(self):
        self.route("/app.zip", b"short", headers={"Content-Length": "100"})
        self.assert_failure(self.run_download(), "100", "5")

    def test_should_explain_insufficient_download_disk_space(self):
        with mock.patch.object(download.shutil, "disk_usage", return_value=mock.Mock(free=17)):
            self.assert_failure(self.run_download(), "disk space", "17")
        self.assertEqual(self.seen, [])

    def test_should_reject_corrupt_or_non_archive_downloads(self):
        for body in (b"<html>login required</html>", b"PK broken zip"):
            with self.subTest(body=body):
                self.route("/app.zip", body)
                self.assert_failure(self.run_download(), "BadZipFile")

    def test_should_reject_unsafe_zip_entries_and_symlinks(self):
        for name in ("../escape", "/escape", "a/../escape", "C:/escape", "a\\escape"):
            with self.subTest(name=name):
                self.route("/app.zip", self.archive([name]))
                self.assert_failure(self.run_download(), "archive path")
                self.assertFalse((self.workspace / "extracted").exists())
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            entry = zipfile.ZipInfo("MyApp.app/link")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, "../../escape")
        self.route("/app.zip", data.getvalue())
        self.assert_failure(self.run_download(), "Special")

    def test_should_apply_archive_safety_checks_to_ipas_too(self):
        self.request["args"]["url"] = self.base + "/build.ipa"
        self.route("/build.ipa", self.archive(["../escape"]))
        self.assert_failure(self.run_download(), "archive path")
        self.assertFalse((self.workspace / "download.ipa").exists())

    def test_should_check_actual_expanded_bytes_for_zips_and_ipas(self):
        for suffix in ("zip", "ipa"):
            for content in (b"x", b"x" * 11):
                with self.subTest(suffix=suffix, size=len(content)):
                    self.request["args"]["url"] = self.base + "/build." + suffix
                    self.route("/build." + suffix, self.archive(["Payload/MyApp.app/Info.plist"]))
                    with mock.patch.object(download.zipfile.ZipFile, "open", return_value=io.BytesIO(content)):
                        self.assert_failure(self.run_download(), "size" if len(content) == 1 else "too large")
                    if (self.workspace / "extracted").exists():
                        shutil.rmtree(self.workspace / "extracted")

    def test_should_preserve_directory_permissions_and_ignore_nested_apps(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            for name, mode, body in (("MyApp.app/", stat.S_IFDIR | 0o750, b""),
                                     ("MyApp.app/MyApp", stat.S_IFREG | 0o755, b"binary"),
                                     ("MyApp.app/Watch/Nested.app/file", stat.S_IFREG | 0o644, b"nested")):
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = mode << 16
                archive.writestr(entry, body)
        self.route("/app.zip", data.getvalue())
        result = self.run_download()
        self.assertEqual(result["output"]["path"], "extracted/MyApp.app")
        self.assertEqual(stat.S_IMODE((self.workspace / result["output"]["path"]).stat().st_mode), 0o750)

    def test_should_stop_when_download_or_extraction_disk_space_runs_out(self):
        for spaces in ([10**9, 17], [10**9, 10**9, 17], [10**9, 10**9, 10**9, 17]):
            with self.subTest(spaces=spaces), mock.patch.object(download.shutil, "disk_usage",
                     side_effect=[mock.Mock(free=free) for free in spaces]):
                self.assert_failure(self.run_download(), "disk space", "17")
            if (self.workspace / "extracted").exists():
                shutil.rmtree(self.workspace / "extracted")

    def test_should_refuse_to_overwrite_a_symlink_download_target(self):
        untouched = self.workspace / "untouched"
        untouched.write_bytes(b"private")
        (self.workspace / "download.bin").symlink_to(untouched)
        self.assert_failure(self.run_download(), "OSError")
        self.assertEqual(untouched.read_bytes(), b"private")

    def test_should_publish_private_atomic_result_files(self):
        self.assertTrue(self.run_download()["ok"])
        self.assertEqual(stat.S_IMODE((self.workspace / "result.json").stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.workspace / "progress.json").stat().st_mode), 0o600)

    def test_should_refuse_conflicting_paths_and_archive_bombs(self):
        for names, config in ((["A/file", "a/other"], {}), (["caf\u00e9", "cafe\u0301"], {}),
                              (["a", "b"], {"maxEntries": 1}),
                              (["MyApp.app/file"], {"maxExpandedBytes": 2})):
            with self.subTest(names=names):
                self.route("/app.zip", self.archive(names))
                self.assert_failure(download.run(self.request, dict(self.config, **config), self.env))
                self.assertFalse((self.workspace / "extracted").exists())

    def test_should_report_ambiguous_apps_and_allow_host_configured_app_selection(self):
        self.route("/app.zip", self.archive(["One.app/file", "build/Two.app/file"]))
        self.assert_failure(self.run_download(), "One.app", "build/Two.app", "found 2")
        shutil.rmtree(self.workspace / "extracted")
        self.config["appPath"] = "build/Two.app"
        self.assertEqual(self.run_download()["output"]["path"], "extracted/build/Two.app")

    def test_should_reject_invalid_envelopes_arguments_and_configuration(self):
        for change in ({"version": True}, {"command": "install"}, {"udid": ""}, {"workspace": "/other"},
                       {"args": {"url": self.base, "headers": {}, "maxArchiveBytes": 1}}):
            with self.subTest(change=change), mock.patch.object(download, "open_response") as open_response:
                self.assert_failure(download.run(dict(self.request, **change), self.config, self.env))
                open_response.assert_not_called()
        for change in ({"maxArchiveBytes": 0}, {"maxEntries": True}, {"maxRedirects": -1},
                       {"requestTimeoutSeconds": 0}, {"appPath": "../App.app"}):
            with self.subTest(change=change), mock.patch.object(download, "open_response") as open_response:
                self.assert_failure(download.run(self.request, dict(self.config, **change), self.env))
                open_response.assert_not_called()

    def test_should_publish_setup_failures_and_explain_unwritable_results_on_stderr(self):
        with mock.patch.object(download.sys, "stdin", io.StringIO("not JSON")), \
             mock.patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(download.main(), 0)
        self.assert_failure(json.loads((self.workspace / "result.json").read_text()), "JSONDecodeError")
        with mock.patch.object(download.sys, "stdin", io.StringIO("not JSON")), \
             mock.patch.dict(os.environ, self.env, clear=True), \
             mock.patch.object(download.artifact, "atomic_json", side_effect=PermissionError("host-secret")), \
             contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(download.main(), 1)
        self.assertIn("PermissionError", stderr.getvalue())
        self.assertNotIn("host-secret", stderr.getvalue())

    def test_should_work_as_an_independently_copied_plugin_with_only_python(self):
        plugin = self.workspace / "plugin"
        shutil.copytree(ROOT / "bin", plugin / "bin", ignore=shutil.ignore_patterns("__pycache__"))
        (plugin / "config.json").write_text(json.dumps(self.config))
        completed = subprocess.run([sys.executable, "-B", str(plugin / "bin/download.py")],
                                   input=json.dumps(self.request), text=True, capture_output=True,
                                   env=self.env, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, "")
        self.assertTrue(json.loads((self.workspace / "result.json").read_text())["ok"])

    def test_should_ship_an_apps_background_command_with_no_secret_environment_requirements(self):
        manifest = json.loads((ROOT / "baguette-plugin.json").read_text())
        self.assertEqual(manifest["name"], "url-download")
        self.assertEqual(manifest["capabilities"], ["apps"])
        self.assertEqual(manifest["contributes"]["commands"], [{"id": "install", "title": "Install app from URL",
                         "run": ["python3", "bin/download.py"], "background": {"timeoutSeconds": 3600}}])
        config = json.loads((ROOT / "config.json").read_text())
        self.assertEqual(config["allowedHosts"], [])
        self.assertFalse(config["allowHTTP"])


if __name__ == "__main__":
    unittest.main()
