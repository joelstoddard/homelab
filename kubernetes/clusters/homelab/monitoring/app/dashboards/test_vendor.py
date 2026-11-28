"""Tests for vendor.py. Run from this directory: python3 -m unittest test_vendor"""
import unittest

from vendor import drop_var


def mixin_dashboard():
    return {
        "annotations": {"list": [
            {"name": "Deployments", "expr": '{cluster=~"$cluster", container="kube-diff-logger"}'},
            {"name": "Kept", "expr": "up"},
        ]},
        "templating": {"list": [
            {"name": "cluster", "query": {"query": "label_values(m, cluster)\n"}},
            {"name": "namespace", "query": {"query": 'label_values(m{cluster=~"$cluster"}, namespace)\n'}},
            {"name": "groupby", "query": "instance,cluster,pod"},
        ]},
        "panels": [{"targets": [
            {"expr": 'sum by (${groupby}) (m{cluster=~"$cluster", namespace=~"$namespace", job=~"$job"})'},
        ]}],
    }


class DropVar(unittest.TestCase):
    def test_removes_variable_matchers_and_annotations(self):
        d = drop_var(mixin_dashboard(), "cluster")
        self.assertEqual([v["name"] for v in d["templating"]["list"]], ["namespace", "groupby"])
        self.assertEqual(d["templating"]["list"][0]["query"]["query"], "label_values(m, namespace)\n")
        self.assertEqual(d["panels"][0]["targets"][0]["expr"],
                         'sum by (${groupby}) (m{namespace=~"$namespace", job=~"$job"})')
        self.assertEqual([a["name"] for a in d["annotations"]["list"]], ["Kept"])

    def test_leaves_the_label_name_in_other_text(self):
        d = drop_var(mixin_dashboard(), "cluster")
        self.assertEqual(d["templating"]["list"][1]["query"], "instance,cluster,pod")

    def test_removes_a_matcher_in_last_position(self):
        d = mixin_dashboard()
        d["panels"][0]["targets"].append({"expr": 'up{job=~"$job", cluster=~"$cluster"}'})
        d = drop_var(d, "cluster")
        self.assertEqual(d["panels"][0]["targets"][1]["expr"], 'up{job=~"$job"}')

    def test_drops_the_variable_from_panel_titles(self):
        d = mixin_dashboard()
        d["panels"].append({"title": "Lines read in $cluster"})
        d["panels"].append({"title": "Active files count $cluster"})
        d = drop_var(d, "cluster")
        self.assertEqual([p.get("title") for p in d["panels"][1:]], ["Lines read", "Active files count"])

    def test_drops_the_variable_from_link_urls(self):
        d = mixin_dashboard()
        d["panels"][0]["links"] = [{"url": "/d/x?var-job=${job}&var-cluster=${cluster}&var-namespace=${namespace}"},
                                   {"url": "/d/y?var-cluster=${cluster}"}]
        d = drop_var(d, "cluster")
        self.assertEqual([l["url"] for l in d["panels"][0]["links"]],
                         ["/d/x?var-job=${job}&var-namespace=${namespace}", "/d/y"])

    def test_fails_on_a_reference_it_cannot_remove(self):
        d = mixin_dashboard()
        d["panels"][0]["targets"].append({"expr": 'm{cluster="$cluster"}'})
        with self.assertRaises(SystemExit):
            drop_var(d, "cluster")

    def test_fails_when_the_variable_is_absent(self):
        with self.assertRaises(SystemExit):
            drop_var(mixin_dashboard(), "region")


if __name__ == "__main__":
    unittest.main()
