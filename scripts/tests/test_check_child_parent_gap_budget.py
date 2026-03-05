import unittest

from scripts.check_child_parent_gap_budget import compute_gap_budget_result


class CheckChildParentGapBudgetTests(unittest.TestCase):
    def test_compute_gap_budget_result_counts_parent_parity_gap(self):
        spec_rest = [
            ("GET", "/api/a"),
            ("GET", "/api/b"),
            ("POST", "/api/c"),
        ]
        spec_ws = ["/ws/a", "/ws/b", "/ws/c"]

        result = compute_gap_budget_result(
            spec_rest=spec_rest,
            spec_ws=spec_ws,
            child_rest_hits={("GET", "/api/a")},
            parent_rest_hits={("GET", "/api/a"), ("GET", "/api/b"), ("POST", "/api/c")},
            child_ws_hits={"/ws/a"},
            parent_ws_hits={"/ws/a", "/ws/b", "/ws/c"},
        )

        self.assertEqual(result.rest_gap_with_parent, 2)
        self.assertEqual(result.ws_gap_with_parent, 2)


if __name__ == "__main__":
    unittest.main()
