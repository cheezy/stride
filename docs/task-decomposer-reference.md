# task-decomposer reference

Reference material for the `stride:task-decomposer` agent, split out of `agents/task-decomposer.md` (W2082) so the agent body is not re-paid on every decomposition dispatch.

**This file carries one worked decomposition — never a rule.** The methodology, the sizing heuristics, the dependency-graph shapes and the output contract all live inline in `agents/task-decomposer.md`. The request envelope for both creation endpoints is owned by the `stride-creating-goals` skill, not by this file and not by the agent body.

## Example: Goal Decomposed into Tasks

### Input (goal from human):

```
"Add task commenting system — users should be able to leave comments on tasks with @mentions and email notifications"
```

### Output (decomposed goal with 4 tasks):

```json
{
  "agent_name": "Claude Opus 4.6",
  "goals": [
    {
      "title": "Add task commenting system with mentions and notifications",
      "type": "goal",
      "complexity": "large",
      "priority": "high",
      "needs_review": false,
      "created_by_agent": "Claude Opus 4.6",
      "description": "Implement a commenting system for tasks that supports @mentions of team members and sends email notifications. This improves team collaboration by enabling asynchronous discussion directly on tasks.",
      "tasks": [
        {
          "title": "Create comment schema, migration, and context functions",
          "type": "work",
          "complexity": "small",
          "priority": "high",
          "needs_review": false,
          "description": "Add the database table and Ecto schema for task comments, plus context functions for CRUD operations. This is the data foundation for the commenting system.",
          "why": "Comments need persistent storage and a clean API before the UI can be built",
          "what": "TaskComment schema with body, user_id, task_id fields; migration; context functions in Tasks module",
          "where_context": "lib/kanban/tasks/ — new TaskComment schema and additions to Tasks context",
          "key_files": [
            {"file_path": "lib/kanban/tasks/task_comment.ex", "note": "New schema file to create", "position": 0},
            {"file_path": "priv/repo/migrations/TIMESTAMP_create_task_comments.exs", "note": "New migration to create", "position": 1},
            {"file_path": "lib/kanban/tasks.ex", "note": "Add comment CRUD functions", "position": 2}
          ],
          "dependencies": [],
          "verification_steps": [
            {"step_type": "command", "step_text": "mix test test/kanban/tasks_test.exs", "expected_result": "All comment CRUD tests pass", "position": 0},
            {"step_type": "command", "step_text": "mix credo --strict", "expected_result": "No issues", "position": 1}
          ],
          "testing_strategy": {
            "unit_tests": ["Test create_comment/2 with valid attrs", "Test create_comment/2 with invalid attrs", "Test list_comments_for_task/1", "Test delete_comment/1"],
            "integration_tests": ["Test comment association with task and user"],
            "edge_cases": ["Empty comment body", "Comment on non-existent task", "Comment by unauthorized user"],
            "coverage_target": "100% for comment context functions"
          },
          "security_considerations": [
            "Authorize that the requesting user may access the task before creating, listing, or deleting its comments",
            "Validate and length-limit the comment body before persisting to prevent oversized/abusive input",
            "Scope delete_comment/1 so a user can only delete comments they are permitted to remove"
          ],
          "acceptance_criteria": "TaskComment schema exists with body, user_id, task_id\nMigration creates task_comments table with indexes\nCRUD functions in Tasks context\nAll tests pass",
          "patterns_to_follow": "Follow existing TaskHistory schema pattern in lib/kanban/tasks/task_history.ex\nFollow context function pattern in lib/kanban/tasks.ex",
          "pitfalls": ["Don't put queries in LiveView — use Tasks context", "Don't forget foreign key indexes on user_id and task_id"]
        },
        {
          "title": "Add comment display and submission UI to task detail view",
          "type": "work",
          "complexity": "medium",
          "priority": "high",
          "needs_review": false,
          "description": "Add a comments section to the task detail view with a form for submitting new comments and a list of existing comments with timestamps and author names.",
          "why": "Users need a visual interface to read and post comments on tasks",
          "what": "Comments section in task detail LiveView with real-time updates via PubSub",
          "where_context": "lib/kanban_web/live/task_live/ — task detail view component",
          "key_files": [
            {"file_path": "lib/kanban_web/live/task_live/view_component.ex", "note": "Add comments section with form and list", "position": 0},
            {"file_path": "lib/kanban_web/live/task_live/view_component.html.heex", "note": "Comment UI template", "position": 1}
          ],
          "dependencies": [0],
          "verification_steps": [
            {"step_type": "command", "step_text": "mix test test/kanban_web/live/task_live/view_component_test.exs", "expected_result": "All comment UI tests pass", "position": 0},
            {"step_type": "manual", "step_text": "Open a task, post a comment, verify it appears immediately", "expected_result": "Comment appears with author and timestamp", "position": 1}
          ],
          "testing_strategy": {
            "unit_tests": ["Test comment form renders", "Test comment submission creates comment", "Test comment list displays existing comments"],
            "integration_tests": ["Test full comment flow: open task, submit comment, see it appear"],
            "manual_tests": ["Verify comment UI in both light and dark mode"],
            "edge_cases": ["Long comment text wrapping", "Many comments scrolling"],
            "coverage_target": "100% for comment LiveView handlers"
          },
          "security_considerations": [
            "Escape/sanitize comment body when rendering to prevent stored XSS",
            "Authorize the socket's current user before accepting a comment submission — never trust a client-supplied user_id",
            "Only broadcast comment updates to users authorized to view the task"
          ],
          "acceptance_criteria": "Comments section visible on task detail view\nComment form with text input and submit button\nExisting comments shown with author name and timestamp\nNew comments appear immediately after submission\nWorks in both light and dark mode",
          "patterns_to_follow": "Follow existing task history rendering pattern in view_component.ex\nFollow form pattern from core_components.ex",
          "pitfalls": ["Don't forget dark mode styles for comments section", "Don't forget translations for comment labels", "Don't add Ecto queries in the LiveView"]
        },
        {
          "title": "Implement @mention parsing and user lookup",
          "type": "work",
          "complexity": "small",
          "priority": "medium",
          "needs_review": false,
          "description": "Parse @username mentions in comment text, resolve them to user records, and highlight them in the rendered comment.",
          "why": "Mentions enable users to direct comments at specific team members, which is the trigger for notifications",
          "what": "Mention parser module that extracts @usernames, resolves to users, and formats highlighted HTML",
          "where_context": "lib/kanban/tasks/ — new mention parsing module",
          "key_files": [
            {"file_path": "lib/kanban/tasks/mentions.ex", "note": "New module for mention parsing and resolution", "position": 0}
          ],
          "dependencies": [0],
          "verification_steps": [
            {"step_type": "command", "step_text": "mix test test/kanban/tasks/mentions_test.exs", "expected_result": "All mention parsing tests pass", "position": 0},
            {"step_type": "command", "step_text": "mix credo --strict", "expected_result": "No issues", "position": 1}
          ],
          "testing_strategy": {
            "unit_tests": ["Test parse_mentions/1 extracts usernames", "Test resolve_mentions/1 maps to user records", "Test format_mentions/1 produces highlighted HTML"],
            "integration_tests": ["Test mention in comment resolves to correct user"],
            "edge_cases": ["@nonexistent_user", "Multiple @mentions in one comment", "@ followed by special characters"],
            "coverage_target": "100% for mentions module"
          },
          "security_considerations": [
            "Never use String.to_atom/1 on parsed @usernames — use String.to_existing_atom/1 or string lookups to avoid atom exhaustion",
            "Bound the number of @mentions and the username length parsed per comment to prevent DoS",
            "Resolve mentions only to users the commenter is permitted to reference; don't leak existence of users outside the board"
          ],
          "acceptance_criteria": "@username mentions parsed from comment text\nMentioned usernames resolved to user records\nMentions highlighted in rendered comment\nInvalid mentions handled gracefully",
          "patterns_to_follow": "Follow existing module pattern in lib/kanban/tasks/ for single-concern modules",
          "pitfalls": ["Don't use String.to_atom/1 for usernames — security risk", "Don't forget to handle mentions of users not on the board"]
        },
        {
          "title": "Add email notifications for mentioned users",
          "type": "work",
          "complexity": "small",
          "priority": "medium",
          "needs_review": false,
          "description": "When a user is @mentioned in a comment, send them an email notification with the comment content and a link to the task.",
          "why": "Email notifications ensure mentioned users are aware of comments even when not actively using the application",
          "what": "Notification email template and delivery logic triggered by mentions in new comments",
          "where_context": "lib/kanban/accounts/ — email notification, lib/kanban/tasks.ex — trigger on comment creation",
          "key_files": [
            {"file_path": "lib/kanban/accounts/user_notifier.ex", "note": "Add mention notification email function", "position": 0},
            {"file_path": "lib/kanban/tasks.ex", "note": "Trigger notification after comment creation with mentions", "position": 1}
          ],
          "dependencies": [0, 2],
          "verification_steps": [
            {"step_type": "command", "step_text": "mix test test/kanban/accounts/user_notifier_test.exs", "expected_result": "Notification email tests pass", "position": 0},
            {"step_type": "command", "step_text": "mix test test/kanban/tasks_test.exs", "expected_result": "Comment + notification integration tests pass", "position": 1}
          ],
          "testing_strategy": {
            "unit_tests": ["Test deliver_mention_notification/3 generates correct email", "Test email contains comment text and task link"],
            "integration_tests": ["Test comment creation with mention triggers notification"],
            "edge_cases": ["User mentioned but has no email", "User mentions themselves"],
            "coverage_target": "100% for notification delivery"
          },
          "security_considerations": [
            "Don't leak whether an email address exists via notification errors or timing — fail quietly",
            "Rate-limit mention notifications per user to prevent comment-spam from becoming an email-bomb vector",
            "Escape comment text embedded in the email body to prevent HTML/email injection"
          ],
          "acceptance_criteria": "Email sent when user is @mentioned in a comment\nEmail contains comment text, commenter name, and task link\nNo email sent for self-mentions\nAll tests pass",
          "patterns_to_follow": "Follow existing notification pattern in lib/kanban/accounts/user_notifier.ex\nFollow Swoosh email delivery pattern",
          "pitfalls": ["Don't send notification for self-mentions", "Don't block comment creation if email fails — use async delivery", "Don't send duplicate emails for multiple mentions of same user"]
        }
      ]
    }
  ]
}
```

**Decomposition rationale:**
- Task 0 (schema) has no dependencies — it's the data foundation
- Task 1 (UI) depends on [0] — needs context functions to display/create comments
- Task 2 (mentions) depends on [0] — needs comment schema but not UI
- Task 3 (notifications) depends on [0, 2] — needs both comments and mention parsing
- Tasks 1 and 2 can run in parallel (fan-out pattern from task 0)
- No key_file overlap between tasks — each modifies different files

