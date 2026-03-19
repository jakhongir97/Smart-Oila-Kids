import unittest

from scripts.generate_child_openapi_gap_report import (
    CoverageSummary,
    format_ops,
    path_domain,
    render_markdown,
)


class GenerateChildOpenAPIGapReportTests(unittest.TestCase):
    def test_path_domain_extracts_first_segment(self):
        self.assertEqual(path_domain("/api/devices/{id}/stream/start"), "devices")
        self.assertEqual(path_domain("/members/me"), "members")
        self.assertEqual(path_domain("/"), "root")

    def test_format_ops_truncates_with_tail_marker(self):
        ops = [("GET", f"/api/items/{index}") for index in range(5)]
        rows = format_ops(ops, limit=3)
        self.assertEqual(len(rows), 4)
        self.assertTrue(rows[-1].startswith("- ... and 2 more"))

    def test_render_markdown_contains_sections(self):
        summary = CoverageSummary(
            rest_spec_count=10,
            rest_child_count=3,
            rest_parent_count=9,
            rest_gap_with_parent_count=6,
            ws_spec_count=5,
            ws_child_count=1,
            ws_parent_count=5,
            ws_gap_with_parent_count=4,
        )
        content = render_markdown(
            report_date="2026-03-05",
            contract_path="OpenAPI/child_openapi_contract.json",
            summary=summary,
            rest_gap_ops=[("GET", "/api/devices/{}")],
            ws_gap_paths=["/ws/{}/parent/device/{}/chat"],
        )

        self.assertIn("# Smart Oila Kids - Child OpenAPI Contract Report", content)
        self.assertIn("## Coverage Snapshot", content)
        self.assertIn("## REST Contract Gaps (Prioritize by Volume)", content)
        self.assertIn("## WebSocket Contract Gaps Already Proven in Parent", content)
        self.assertIn("- Child contract: `OpenAPI/child_openapi_contract.json`", content)


if __name__ == "__main__":
    unittest.main()
