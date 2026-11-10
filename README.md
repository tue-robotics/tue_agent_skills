# tue_agent_skills

Shared [Agent Skills](https://agentskills.io/specification) for tue-robotics — reusable, tested reference guides that any compliant coding-agent CLI (Claude Code, Codex, Gemini CLI, Copilot CLI, ...) can load. Same idea as [`tue_lint_config`](https://github.com/tue-robotics/tue_lint_config) sharing clang-format/clang-tidy config, but for agent know-how instead of linter config.

This repo is tool-agnostic on purpose: skills are plain `SKILL.md` files following the generic spec, not Claude Code plugins. Nothing stops you from also wrapping this repo as a Claude Code plugin later if the team standardizes on one tool — see [Also using this as a Claude Code plugin](#also-using-this-as-a-claude-code-plugin) below.

## Layout

```
skills/
  <skill-name>/
    SKILL.md            # required: frontmatter (name, description) + content
    <supporting-file>*  # only if the skill needs heavy reference docs or reusable tools
```

## Using these skills

Most agent CLIs load skills from a per-tool directory (e.g. `~/.claude/skills/` for Claude Code) and/or the cross-runtime alias `~/.agents/skills/` (read by Codex, Copilot CLI and Gemini CLI).

Clone this repo once, then symlink the skills you want in:

```bash
git clone git@github.com:tue-robotics/tue_agent_skills.git ~/src/tue_agent_skills
./install.sh
```

`install.sh` symlinks every skill under `skills/` into both `~/.agents/skills/` and `~/.claude/skills/`, so `git pull` in this repo keeps every tool's skills up to date with no copying. Re-run it after a new skill is added, since each skill is its own link. To install only selected skills, or into another tool-specific directory, symlink individual skill folders directly, e.g.:

```bash
ln -s ~/src/tue_agent_skills/skills/migrating-ros1-to-ros2 ~/.claude/skills/migrating-ros1-to-ros2
```

## Current skills

| Skill | Use when |
|---|---|
| [`migrating-ros1-to-ros2`](skills/migrating-ros1-to-ros2/SKILL.md) | Migrating a ROS1/catkin package to ROS2/ament — package.xml/CMakeLists.txt conversion, roscpp→rclcpp porting, message/interface splits, nodelet→component, or deciding whether to deprecate a package instead |

## Adding a new skill

1. One skill = one directory under `skills/`, named with lowercase letters/numbers/hyphens, verb-first where it names a process (e.g. `migrating-x-to-y`, not `x-to-y-migration`).
2. `SKILL.md` needs YAML frontmatter with `name` and `description`. Write the description in third person, starting with "Use when...", describing only the triggering conditions — not the skill's process (agents will follow the description instead of reading the skill if it summarizes the workflow).
3. Ground the content in real evidence (actual code/config from this org's repos, actual commands you ran) rather than generic advice from memory — cite the repo/commit/file where relevant. This is what made the first skill in this repo useful; keep the bar there.
4. Split heavy reference material (100+ lines of API tables, long code walkthroughs) into separate `.md` files alongside `SKILL.md`, cross-referenced by relative link. Keep `SKILL.md` itself as the overview + decision points + quick-reference table.
5. Before merging, actually exercise the skill: have a fresh agent (no prior context) apply it to a small real or representative task and check the output — this is how the gaps in `migrating-ros1-to-ros2`'s first draft got caught (missing "plain node" example, ambiguous callback signature).

## Also using this as a Claude Code plugin

If everyone ends up on Claude Code, this repo can be turned into an installable plugin without moving anything: add a `.claude-plugin/plugin.json` manifest at the repo root pointing at `skills/`, then register the repo as a marketplace source. That's additive — the plain `skills/` layout stays valid for every other tool, so there's no need to do this preemptively.
