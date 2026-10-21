import unittest

from check_panels import substitute


class SubstituteTest(unittest.TestCase):
    def test_substitute_keeps_literal_windows(self):
        self.assertEqual(substitute("rate(x[1m])"), "rate(x[1m])")
        self.assertEqual(substitute("rate(x[$__rate_interval])"), "rate(x[5m])")

    def test_substitute_variables(self):
        self.assertEqual(substitute('up{namespace=~"$namespace", pod="${pod}"}'),
                         'up{namespace=~".*", pod=~".*"}')

    def test_substitute_negative_matcher(self):
        self.assertEqual(substitute('up{job!~"$job", pod!="${pod}"}'),
                         'up{job!~"__no_such_value__", pod!="__no_such_value__"}')

    def test_substitute_keeps_regex_capture_references(self):
        self.assertEqual(substitute('label_replace(x, "service", "$1", "service", "(a).*")'),
                         'label_replace(x, "service", "$1", "service", "(a).*")')


if __name__ == "__main__":
    unittest.main()
