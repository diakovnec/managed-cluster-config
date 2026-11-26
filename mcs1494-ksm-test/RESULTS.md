# MCS-1494 final test run: results

Stage management cluster, ROSA HCP 4.19.46 hosted cluster, rule under test: `scoped/60-test-rule.PrometheusRule.yaml`
(the PR's expression, reading the scoped metric `capitest_machine_info`).

| # | Scenario | Expected | Result | Evidence (UTC) |
|---|---|---|---|---|
| 1 | Manual `delete machine` | no alert, no service log | pending | |
| 2 | One failed node | `owner_remediated="False"` on the machine, alert fires, one service log | pending | |
| 3 | Second failure inside the window | alert fires, service log count unchanged | pending | |
| 4 | Two nodes of the same pool fail (within the MHC limit of 2) | both flagged with `owner_remediated="False"`, alert for both, both replaced | pending | |
| 5 | Three nodes of the same pool fail (over the limit) | flagged without `owner_remediated`, MHC `TooManyUnhealthy`, no alert, no service log | pending | |

Execution order: 1, 5, 2, 3, 4. Scenario 5 goes early because it does not use up the service log window, and 2, 3 and 4
must land within one hour of each other (window lowered to 1 hour; see the README).

Earlier results with previous versions of the rule are in the PR description.
