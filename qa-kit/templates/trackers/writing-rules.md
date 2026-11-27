# Writing for ClickUp

Read this before you write any title, description, comment or check that goes into ClickUp. The
people who read it were in the meeting. Write for them.

## Rules

- Write like a person on the team who was in the meeting. Do not explain the product back to the
  reader or define terms they already use.
- Keep titles short and plain: the symptom or the action, lowercase after the first word. No
  headline style, no inflating adjectives, no metaphors.
- No emojis.
- Describe what the reader will see on screen. Leave out commit hashes, pull request numbers,
  version internals, file names, code terms, criterion ids and rule ids.
- Do not mention AI, agents or automation, and do not sign anything.
- Do not give every item the same template. A parent ticket is a one-line goal and its list.
- Never mention or tag a person unless the project's tracker config names who to tag and when.
- Test data in examples follows the project's data rules.

## Screenshots

Screenshots are sent as they are. Use test accounts and test data only.

## What is checked

`tracker.sh lint` catches what a script can: emojis, forbidden words and patterns from the config,
id-like tokens, title length and headline case, and empty or repeated text. A failed lint blocks
the push for that item. The rest is on the writer.

## Language

All text for a project is in one language, set by `language` in `docs/agents/qa-tracker.json`
(default `en`). These rules apply in whichever language is set.
