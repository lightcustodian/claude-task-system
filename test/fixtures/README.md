# Test Fixtures

Sample .md files for testing CTS v2 turn detection, scheduling, and invoker logic.

## Directories

- `user-file/` — Initial user prompt (001_*). Has `<User>` signal at end.
- `claude-response/` — Claude's response (002_*). Has `<!-- CLAUDE-RESPONSE -->` header and `# <User>` footer.
- `edited-response/` — User-edited response with `ME:` annotation and `<User>` signal (# removed).
- `stop-signal/` — Response containing `<Stop>` signal — conversation should end.
- `complexity-metadata/` — Files with `<!-- complexity: high -->` metadata for routing tests.

## Expected Behavior

| Fixture | detect_turn() | detect_stop() | get_task_complexity() |
|---------|---------------|---------------|----------------------|
| user-file/001_test-task.md | user_ready | false | medium (default) |
| claude-response/002_test-task.md | claude_responded | false | — |
| edited-response/002_test-task.md | user_ready | false | — |
| stop-signal/003_test-task.md | — | true | — |
| complexity-metadata/001_complex-task.md | user_ready | false | high |
