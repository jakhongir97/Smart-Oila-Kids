import unittest

from scripts.check_rc_go_no_go_checklist import validate


class RCGoNoGoChecklistTests(unittest.TestCase):
    def test_validate_passes_for_complete_checklist(self):
        content = """# Smart Oila Kids - RC Go/No-Go Checklist
Date: 2026-03-05

## Gate Results
- Script tests: PASS
- Child OpenAPI baseline: PASS
- Localization parity: PASS
- Localization format specifiers: PASS
- Parent-child simulator smoke: PASS
- Build warning gate: PASS

## Dependencies
- Parent repository path resolved.

## Risks
- Real-device APNs validation pending.

## Rollback Plan
Rollback trigger: Sev1 regression in production.
Rollback steps:
1. Disable rollout.

## Decision & Sign-Off
Decision: GO
Sign-offs:
- PM: Pending
"""
        self.assertEqual(validate(content), [])

    def test_validate_fails_when_required_markers_missing(self):
        content = "# Smart Oila Kids - RC Go/No-Go Checklist\nDecision: GO\n"
        errors = validate(content)

        self.assertTrue(any("Missing required section" in error for error in errors))
        self.assertTrue(any("Missing rollback trigger" in error for error in errors))
        self.assertTrue(any("Missing Date line" in error for error in errors))

    def test_validate_fails_when_decision_missing(self):
        content = """# Smart Oila Kids - RC Go/No-Go Checklist
Date: 2026-03-05

## Gate Results
- Script tests: PASS
- Child OpenAPI baseline: PASS
- Localization parity: PASS
- Localization format specifiers: PASS
- Parent-child simulator smoke: PASS
- Build warning gate: PASS

## Dependencies
- Parent repository path resolved.

## Risks
- None.

## Rollback Plan
Rollback trigger: Sev1 issue.
Rollback steps:
1. Stop rollout.

## Decision & Sign-Off
Sign-offs:
- PM: Pending
"""
        errors = validate(content)
        self.assertTrue(any("Missing decision line" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
