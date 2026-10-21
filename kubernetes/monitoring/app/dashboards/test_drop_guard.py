import unittest

from drop_guard import collect, conflicts, drop_regexes, metric_names

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

    def test_metric_names_label_values(self):
        self.assertEqual(metric_names("label_values(kube_pod_info, namespace)"), {"kube_pod_info"})
        self.assertEqual(metric_names('label_values(kube_pod_info{namespace="$ns"}, pod)'), {"kube_pod_info"})
        self.assertEqual(metric_names("query_result(count by (node) (node_uname_info))"), {"node_uname_info"})
        self.assertEqual(metric_names("label_values(job)"), set())

    def test_collect_reads_templating_and_annotations(self):
        dash = {
            "panels": [{"type": "row", "panels": [{"targets": [{"expr": "rate(panel_metric_total[1m])"}]}]},
                       {"datasource": {"uid": "loki"}, "targets": [{"expr": 'count_over_time({a="b"}[5m])'}]}],
            "templating": {"list": [
                {"type": "query", "query": {"query": "label_values(var_metric, node)"}},
                {"type": "query", "datasource": {"uid": "loki"}, "query": "label_values(loki_label)"},
                {"type": "interval", "query": "1m,5m"}]},
            "annotations": {"list": [{"expr": "changes(annotation_metric[5m]) > 0"}]},
        }
        self.assertEqual(collect(dash), {"panel_metric_total", "var_metric", "annotation_metric"})

    def test_drop_regexes_only_name_drops(self):
        self.assertEqual(drop_regexes(RIVER), ["apiserver_(watch|storage)_.*"])

    def test_conflict_on_prefix_regex(self):
        self.assertEqual(conflicts({"apiserver_request_total"}, ["apiserver_request_.*"]),
                         [("apiserver_request_total", "apiserver_request_.*")])

    def test_no_conflict_partial_match(self):
        self.assertEqual(conflicts({"apiserver_request_total"}, ["apiserver_request"]), [])


if __name__ == "__main__":
    unittest.main()
