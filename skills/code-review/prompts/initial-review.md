# Initial review prompt

Placeholder. Implementation pending.

This prompt will instruct Claude to perform a first-time review of a PR, producing:
- A review body with overall assessment
- Inline findings (severity, file, line, message, finding ID)
- A verdict (`REQUEST_CHANGES` if any blocker/major; otherwise `COMMENT`)
