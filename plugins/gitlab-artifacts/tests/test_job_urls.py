import unittest
import test_projects as projects


class JobURLTests(unittest.TestCase):
    setUp = projects.ProjectTests.setUp
    archive = projects.ProjectTests.archive
    run_download = projects.ProjectTests.run_download
    assert_prepared = projects.ProjectTests.assert_prepared

    def test_should_prepare_a_job_link_from_the_configured_gitlab_host(self):
        for suffix in ("", "/", "/artifacts/browse", "/artifacts/download", "?foo=bar#artifacts"):
            with self.subTest(suffix=suffix):
                self.request["args"] = {"url": "https://gitlab.example.com/ios/PhonePe/-/jobs/456" + suffix}
                self.assertEqual(projects.download.job_reference(self.request["args"], self.config["host"]), ("ios/PhonePe", 456))
        self.assert_prepared(self.run_download())

    def test_should_prepare_a_nested_project_from_a_job_link(self):
        self.request["args"] = {"url": "https://gitlab.example.com/group/sub_group/My.App/-/jobs/456"}
        self.routes = {"projects/group%2Fsub_group%2FMy.App": self.project}
        self.assert_prepared(self.run_download())

    def test_should_refuse_job_links_that_do_not_match_host_policy_or_job_syntax(self):
        for url in (
            "https://attacker.test/ios/PhonePe/-/jobs/456",
            "http://gitlab.example.com/ios/PhonePe/-/jobs/456",
            "https://user:password@gitlab.example.com/ios/PhonePe/-/jobs/456",
            "https://gitlab.example.com:8443/ios/PhonePe/-/jobs/456",
            "https://gitlab.example.com/ios/PhonePe/-/pipelines/456",
            "https://gitlab.example.com/ios/PhonePe/-/jobs/0",
            "https://gitlab.example.com/ios/PhonePe/-/jobs/456/unrelated",
            "https://gitlab.example.com/ios/../PhonePe/-/jobs/456",
        ):
            with self.subTest(url=url):
                self.request["args"] = {"url": url}
                result = self.run_download()
                self.assertFalse(result["ok"])
                self.assertEqual(self.calls, [])

    def test_should_enforce_the_project_allowlist_for_a_job_link(self):
        self.request["args"] = {"url": "https://gitlab.example.com/ios/PhonePe/-/jobs/456"}
        self.routes["projects/ios%2FPhonePe"] = dict(self.project, id=999)
        result = self.run_download()
        self.assertFalse(result["ok"])
        self.assertIn("Unapproved project", result["message"])
