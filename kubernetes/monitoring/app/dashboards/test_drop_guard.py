import unittest

from drop_guard import conflicts, drop_regexes, metric_names

RIVER = '''
prometheus.relabel "x" {
	rule {
		source_labels = ["__name__"]
		regex         = "apiserver_(watch|storage)_.*"
		action        = "drop"
	}
	rule {
		source_labels = ["__name__"]
		regex         = "up"
		action        = "keep"
	}
	rule {
		source_labels = ["job"]
		regex         = "noisy"
		action        = "drop"
	}
}
'''


class DropGuardTest(unittest.TestCase):
    def test_metric_names_skip_functions_and_labels(self):
        expr = ('histogram_quantile(0.95, sum by (le, service) '
                '(rate(traefik_service_request_duration_seconds_bucket{service=~"$svc"}[$__rate_interval])))')
        self.assertEqual(metric_names(expr), {"traefik_service_request_duration_seconds_bucket"})

    def test_metric_names_binary_expression(self):
        expr = ('container_memory_working_set_bytes{container!=""} / '
                'kube_pod_container_resource_limits{resource="memory"}')
        self.assertEqual(metric_names(expr), {"container_memory_working_set_bytes",
                                              "kube_pod_container_resource_limits"})

    def test_drop_regexes_only_name_drops(self):
        self.assertEqual(drop_regexes(RIVER), ["apiserver_(watch|storage)_.*"])

    def test_conflict_on_prefix_regex(self):
        self.assertEqual(conflicts({"apiserver_request_total"}, ["apiserver_request_.*"]),
                         [("apiserver_request_total", "apiserver_request_.*")])

    def test_no_conflict_partial_match(self):
        self.assertEqual(conflicts({"apiserver_request_total"}, ["apiserver_request"]), [])


if __name__ == "__main__":
    unittest.main()
