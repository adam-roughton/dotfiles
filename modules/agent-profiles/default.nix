# Agent profiles: one image, several agent types. Each profile is a directory
#
#   ~/.config/agent-profiles/<profile>/
#     opencode.json     opencode overlay (skills.paths + per-profile settings)
#     skills/<skill>/   the profile's skills (base skills + its own)
#
# Launchers select a profile with OPENCODE_CONFIG=<dir>/opencode.json; Pi takes
# `--skill <dir>/skills`. Nothing is placed in the directories agents scan
# automatically (~/.config/opencode/skills, ~/.agents/skills, ~/.claude/skills),
# so a skill only reaches the profiles that list it.
{ config, pkgs, lib, ... }:
let
  cfg = config.dotfiles.agentProfiles;
  json = pkgs.formats.json { };
  directory = ".config/agent-profiles";

  skillNamePattern = "[a-z0-9]+(-[a-z0-9]+)*";
  profileNamePattern = "[a-z0-9][a-z0-9_-]*";

  # Home Manager assertions are not checked when the image is built (it reads
  # home-files directly), so report configuration errors with throw.
  checkedProfileName = name:
    if builtins.match profileNamePattern name != null then name
    else throw "dotfiles.agentProfiles.profiles: invalid profile name '${name}' (use lowercase letters, digits, '-' and '_')";
  skillsOf = name: profile: lib.unique (cfg.baseSkills ++ profile.skills);
  skillFor = profileName: skill:
    if !(cfg.skills ? ${skill}) then
      throw "dotfiles.agentProfiles: profile '${profileName}' uses skill '${skill}', which is not defined in dotfiles.agentProfiles.skills"
    else if builtins.match skillNamePattern skill == null || builtins.stringLength skill > 64 then
      throw "dotfiles.agentProfiles.skills: invalid skill name '${skill}' (lowercase letters, digits and single hyphens, at most 64 characters)"
    else cfg.skills.${skill};
  usedSkills = lib.unique (lib.concatLists (lib.mapAttrsToList skillsOf cfg.profiles));

  opencodeConfig = name: profile:
    json.generate "agent-profile-${name}-opencode.json" (lib.recursiveUpdate profile.opencodeSettings {
      "$schema" = "https://opencode.ai/config.json";
      # opencode replaces (does not append) arrays from later config layers.
      skills.paths = [ "${config.home.homeDirectory}/${directory}/${name}/skills" ]
        ++ lib.attrByPath [ "skills" "paths" ] [ ] profile.opencodeSettings;
    });

  # String interpolation (not toString) so local paths are copied to the store.
  linkSkill = profileName: skill: ''
    check_skill ${lib.escapeShellArg skill} ${lib.escapeShellArg "${(skillFor profileName skill).source}"}
    ln -s ${lib.escapeShellArg "${(skillFor profileName skill).source}"} "$out"/${lib.escapeShellArg "${profileName}/skills/${skill}"}
  '';

  profiles = pkgs.runCommand "agent-profiles" { } ''
    fail() { printf 'dotfiles.agentProfiles: %s\n' "$*" >&2; exit 1; }
    # Catch skills that agents would silently skip: opencode and Pi ignore
    # SKILL.md files without frontmatter or a description.
    check_skill() {
      local name="$1" file="$2/SKILL.md" frontmatter
      [ -f "$file" ] || fail "skill '$name': $file does not exist"
      [ "$(head -n 1 "$file")" = --- ] || fail "skill '$name': SKILL.md must start with '---' frontmatter"
      frontmatter="$(awk 'NR == 1 { next } /^---[[:space:]]*$/ { found = 1; exit } { print } END { exit !found }' "$file")" ||
        fail "skill '$name': SKILL.md frontmatter is not closed with '---'"
      grep -Eq "^name:[[:space:]]*[\"']?$name[\"']?[[:space:]]*$" <<< "$frontmatter" ||
        fail "skill '$name': frontmatter must contain 'name: $name' (matching the catalog key)"
      grep -Eq '^description:[[:space:]]*[^[:space:]]' <<< "$frontmatter" ||
        fail "skill '$name': frontmatter must contain a description"
    }
    mkdir -p "$out"
    ${lib.concatStrings (lib.mapAttrsToList (name: profile: ''
      mkdir -p "$out"/${lib.escapeShellArg "${checkedProfileName name}/skills"}
      ln -s ${opencodeConfig name profile} "$out"/${lib.escapeShellArg "${name}/opencode.json"}
      ${lib.concatMapStrings (linkSkill name) (skillsOf name profile)}
    '') cfg.profiles)}
  '';
in
with lib; {
  options.dotfiles.agentProfiles = {
    skills = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          source = mkOption {
            type = types.path;
            example = literalExpression ''../../skills/task-handover'';
            description = ''
              Skill directory containing SKILL.md (and any scripts or references it uses). Its frontmatter
              `name` must equal the attribute name. Use a path in this repository, or a directory inside
              a `flake = false` input for third-party skills.
            '';
          };
          packages = mkOption {
            type = types.listOf types.package;
            default = [ ];
            description = "Packages the skill's instructions or scripts call. Installed when a profile uses the skill.";
          };
        };
      });
      default = { };
      description = "Catalog of available skills, keyed by skill name. Only skills listed by a profile are installed.";
    };

    baseSkills = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Skills added to every profile.";
    };

    profiles = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          skills = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Skills for this profile, in addition to baseSkills.";
          };
          opencodeSettings = mkOption {
            type = json.type;
            default = { };
            example = literalExpression ''{ permission.edit = "deny"; mcp.playwright.enabled = false; }'';
            description = ''
              Extra opencode configuration for this profile (MCP servers, permissions, instructions, ...).
              Merged over ~/.config/opencode/opencode.json; project config and the launcher's
              OPENCODE_CONFIG_CONTENT are merged over it. Arrays replace rather than append, so
              skills.paths given here are kept by adding them after the profile's own skills directory.
            '';
          };
        };
      });
      default = { };
      description = ''
        Agent profiles, keyed by name. Each is installed in ~/.config/agent-profiles/<name>/ and selected
        at launch with OPENCODE_CONFIG=~/.config/agent-profiles/<name>/opencode.json.
      '';
    };
  };

  config = mkIf (cfg.profiles != { }) {
    home.file.${directory}.source = profiles;
    home.packages = concatMap (skill: cfg.skills.${skill}.packages or [ ]) usedSkills;
  };
}
