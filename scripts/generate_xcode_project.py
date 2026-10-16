#!/usr/bin/env python3
"""Generate `JarvisApp.xcodeproj` from the repository's file tree.

Why a generator instead of a hand-edited project: Xcode project files are large,
mergetastic and must be regenerated whenever files move. This script keeps the
project in sync with the sources in one command, needs no macOS, and refuses to
write a project it cannot verify.

The app target compiles the app layer *and* the JarvisCore sources directly (the
same files the SwiftPM package builds for Linux tests), so a single project file
has no external package resolution step that could fail on CI.

Usage:  python3 scripts/generate_xcode_project.py [--check]
        --check            verify the committed project matches the file tree (CI mode)
        --verify PBXPROJ   parse an existing project file, check every reference
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys

BUNDLE_ID = "ai.jarvis.assistant"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.9"
TARGET_NAME = "JarvisApp"
PROJECT_NAME = "JarvisApp"
APP_DIR = "JarvisApp"
CORE_DIR = "JarvisCore/Sources/JarvisCore"

SOURCE_EXTENSIONS = {".swift": "sourcecode.swift"}
RESOURCE_TYPES = {".xcassets": "folder.assetcatalog"}
PLIST_TYPE = "text.plist.xml"


def uuid_for(key: str) -> str:
    """Deterministic 24-hex-character object identifier."""
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:24].upper()


# ---------------------------------------------------------------------------
# Old-style (OpenStep) plist support.
#
# The first macOS CI run failed with:
#   "xcodebuild: error: Unable to read project 'JarvisApp.xcodeproj'"
#   "Old-style plist parser: missing semicolon in dictionary on line 570"
# because a build setting was emitted as `TARGETED_DEVICE_FAMILY = 1,2;` — a comma
# is structural in this format, so the value has to be quoted ("1,2"). The
# balance-and-regex checks this script used before could not see that.
#
# So the project file is now *parsed* here, with a real parser for the grammar
# Xcode uses, and every object reference is resolved before the file is written.
# Nothing is written that does not parse.
# ---------------------------------------------------------------------------

BARE_SAFE = re.compile(r"^[A-Za-z0-9_]+([./][A-Za-z0-9_]+)*$")
REFERENCE = re.compile(r"^[0-9A-F]{24}$")

REQUIRED_ISA = (
    "PBXProject", "PBXNativeTarget", "PBXGroup", "PBXFileReference", "PBXBuildFile",
    "PBXSourcesBuildPhase", "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase",
    "XCConfigurationList", "XCBuildConfiguration",
)


def plist_quote(value: str) -> str:
    """Quotes a value the way Xcode does: bare only when it is unambiguously a token.

    Bare values must not contain `,` `(` `)` `{` `}` `=` `;` `"` whitespace `$` `-`
    or anything else the grammar treats specially — quoting is always safe, so the
    rule is deliberately conservative.
    """
    if value and BARE_SAFE.match(value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


class PlistSyntaxError(ValueError):
    """Raised with a line number when the generated text is not valid."""


def parse_openstep(text: str):  # noqa: C901 - a parser is naturally branchy
    """Parses an old-style plist. Returns nested dicts/lists/strings.

    Enforces the two rules that actually bite in hand-generated project files:
    every dictionary entry ends with `;`, and array elements are comma-separated.
    """
    index = 0
    length = len(text)

    def fail(message: str, position: int) -> None:
        line = text.count("\n", 0, position) + 1
        column = position - (text.rfind("\n", 0, position) + 1) + 1
        raise PlistSyntaxError(f"line {line}, column {column}: {message}")

    def skip_trivia() -> None:
        nonlocal index
        while index < length:
            char = text[index]
            if char.isspace():
                index += 1
            elif text.startswith("/*", index):
                end = text.find("*/", index + 2)
                if end == -1:
                    fail("unterminated /* comment", index)
                index = end + 2
            elif text.startswith("//", index):
                end = text.find("\n", index)
                index = length if end == -1 else end + 1
            else:
                return

    def parse_quoted() -> str:
        nonlocal index
        index += 1
        out: list[str] = []
        escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'"}
        while index < length:
            char = text[index]
            if char == "\\":
                nxt = text[index + 1] if index + 1 < length else ""
                if nxt in escapes:
                    out.append(escapes[nxt])
                    index += 2
                    continue
                if nxt in ("u", "U") and index + 6 <= length:
                    digits = text[index + 2:index + 6]
                    try:
                        out.append(chr(int(digits, 16)))
                        index += 6
                        continue
                    except ValueError:
                        fail("malformed unicode escape", index)
                out.append(nxt)
                index += 2
                continue
            if char == '"':
                index += 1
                return "".join(out)
            out.append(char)
            index += 1
        fail("unterminated quoted string", index)

    def parse_bare() -> str:
        nonlocal index
        start = index
        while index < length and text[index] not in ' \t\r\n;,=(){}"':
            index += 1
        if index == start:
            fail(f"unexpected character {text[index]!r}", index)
        return text[start:index]

    def parse_value():
        nonlocal index
        skip_trivia()
        if index >= length:
            fail("unexpected end of file", index)
        char = text[index]
        if char == "{":
            return parse_dict()
        if char == "(":
            return parse_array()
        if char == '"':
            return parse_quoted()
        return parse_bare()

    def parse_dict() -> dict:
        nonlocal index
        index += 1  # consume '{'
        result: dict[str, object] = {}
        while True:
            skip_trivia()
            if index >= length:
                fail("unterminated dictionary", index)
            if text[index] == "}":
                index += 1
                return result
            key = parse_quoted() if text[index] == '"' else parse_bare()
            skip_trivia()
            if index >= length or text[index] != "=":
                fail(f"expected '=' after key {key!r}", index)
            index += 1
            value = parse_value()
            skip_trivia()
            if index >= length:
                fail(f"missing ';' after the value of {key!r}", index)
            if text[index] != ";":
                fail(f"missing ';' after the value of {key!r} (found {text[index]!r})", index)
            index += 1
            result[key] = value

    def parse_array() -> list:
        nonlocal index
        index += 1  # consume '('
        items: list[object] = []
        while True:
            skip_trivia()
            if index >= length:
                fail("unterminated array", index)
            if text[index] == ")":
                index += 1
                return items
            items.append(parse_value())
            skip_trivia()
            if index < length and text[index] == ",":
                index += 1
                continue
            if index < length and text[index] == ")":
                index += 1
                return items
            fail("expected ',' or ')' in array", index)

    value = parse_value()
    skip_trivia()
    if index != length:
        fail("unexpected trailing content", index)
    return value


def _references(node) -> list[str]:
    found: list[str] = []
    stack = [node]
    while stack:
        current = stack.pop()
        if isinstance(current, dict):
            stack.extend(current.values())
        elif isinstance(current, list):
            stack.extend(current)
        elif isinstance(current, str) and REFERENCE.match(current):
            found.append(current)
    return found


def verify_project_text(text: str) -> tuple[list[str], dict]:
    """Parses the project text and checks structure and every object reference.

    Returns (problems, statistics). An empty `problems` list means the text is
    something Xcode can read.
    """
    stats: dict = {}
    try:
        document = parse_openstep(text)
    except PlistSyntaxError as error:
        return [f"the project file is not a valid old-style plist — {error}"], stats

    problems: list[str] = []
    if not isinstance(document, dict):
        return ["the project file does not contain a top-level dictionary"], stats

    objects = document.get("objects")
    if not isinstance(objects, dict):
        return ["the project file has no `objects` dictionary"], stats

    root = document.get("rootObject")
    if not isinstance(root, str) or root not in objects:
        problems.append("`rootObject` is missing or does not resolve to an object")

    isa_types: list[str] = []
    for identifier, body in objects.items():
        if not isinstance(body, dict) or "isa" not in body:
            problems.append(f"object {identifier} has no `isa`")
            continue
        isa_types.append(str(body["isa"]))

    for required in REQUIRED_ISA:
        if required not in isa_types:
            problems.append(f"the project has no {required} object")

    missing = sorted({ref for ref in _references(objects) if ref not in objects})
    if missing:
        problems.append(f"references to undefined objects: {', '.join(missing[:5])}")

    for identifier, body in objects.items():
        if not isinstance(body, dict):
            continue
        isa = body.get("isa")
        if isa == "PBXBuildFile" and body.get("fileRef") not in objects:
            problems.append(f"PBXBuildFile {identifier} points at a missing file reference")
        if isa == "PBXGroup":
            for child in body.get("children", []) or []:
                if child not in objects:
                    problems.append(f"PBXGroup {identifier} has a missing child {child}")
        if isa == "PBXNativeTarget":
            if body.get("buildConfigurationList") not in objects:
                problems.append(f"target {identifier} has no configuration list")
            for phase in body.get("buildPhases", []) or []:
                if phase not in objects:
                    problems.append(f"target {identifier} has a missing build phase {phase}")

    stats["objects"] = len(objects)
    stats["groups"] = isa_types.count("PBXGroup")
    stats["swift_sources"] = text.count("sourcecode.swift;")
    stats["build_configurations"] = isa_types.count("XCBuildConfiguration")
    return problems, stats


def verify_file(path: pathlib.Path) -> int:
    """`--verify <project.pbxproj>`: standalone syntax and structure check."""
    if not path.exists():
        print(f"ERROR: {path} does not exist")
        return 1
    problems, stats = verify_project_text(path.read_text())
    if problems:
        for problem in problems:
            print(f"ERROR: {problem}")
        return 1
    print(f"{path}: parses as an old-style plist — {stats['objects']} objects, "
          f"{stats['groups']} groups, {stats['swift_sources']} Swift sources, "
          f"{stats['build_configurations']} build configurations")
    return 0


def collect(root: pathlib.Path, base: pathlib.Path) -> list[pathlib.Path]:
    """Every .swift file under base, plus asset catalogs, sorted for stability."""
    items: list[pathlib.Path] = []
    for path in sorted(base.rglob("*")):
        if path.is_dir():
            if path.suffix == ".xcassets":
                items.append(path)
            continue
        if path.suffix in SOURCE_EXTENSIONS:
            items.append(path)
    return items


class ProjectBuilder:
    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        self.objects: dict[str, str] = {}   # uuid -> serialised object body
        self.order: list[str] = []          # insertion order for stable output

    def add(self, key: str, body: str) -> str:
        identifier = uuid_for(key)
        if identifier not in self.objects:
            self.objects[identifier] = body
            self.order.append(identifier)
        return identifier

    # -- sections -----------------------------------------------------------
    def file_reference(self, path: pathlib.Path, file_type: str) -> str:
        relative = path.relative_to(self.root)
        return self.add(f"fileref:{relative}",
                        f'{{isa = PBXFileReference; lastKnownFileType = {file_type}; '
                        f'path = {plist_quote(path.name)}; sourceTree = "<group>"; }};')

    def build_file(self, path: pathlib.Path, file_type: str, phase: str) -> str:
        reference = self.file_reference(path, file_type)
        relative = path.relative_to(self.root)
        return self.add(f"buildfile:{relative}:{phase}",
                        f"{{isa = PBXBuildFile; fileRef = {reference} /* {path.name} */; }};")

    def group(self, name: str, children: list[str], path: str | None = None) -> str:
        child_list = "\n".join(f"\t\t\t\t{child}," for child in children)
        path_line = f"\t\t\tpath = {plist_quote(path)};\n" if path else ""
        return self.add(f"group:{name}:{path}",
                        "{\n"
                        "\t\t\tisa = PBXGroup;\n"
                        "\t\t\tchildren = (\n"
                        f"{child_list}\n"
                        "\t\t\t);\n"
                        f"{path_line}"
                        "\t\t\tsourceTree = \"<group>\";\n"
                        "\t\t};")


def build_settings(configuration: str) -> str:
    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "SWIFT_VERSION": SWIFT_VERSION,
        "TARGETED_DEVICE_FAMILY": "1,2",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": f"{APP_DIR}/Info.plist",
        "MARKETING_VERSION": "1.0.0",
        "OTHER_LDFLAGS": "-lsqlite3",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "VALIDATE_PRODUCT": "YES",
    }
    if configuration == "Debug":
        common.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_DYNAMIC_NO_PIC": "NO",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": "DEBUG=1 $(inherited)",
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "MTL_FAST_MATH": "YES",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
        })
    else:
        common.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "ENABLE_NS_ASSERTIONS": "NO",
            "MTL_ENABLE_DEBUG_INFO": "NO",
            "MTL_FAST_MATH": "YES",
            "SWIFT_COMPILATION_MODE": "wholemodule",
        })
    body = "\n".join(f"\t\t\t\t{key} = {plist_quote(value)};" for key, value in sorted(common.items()))
    return ("{\n"
            "\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbuildSettings = {\n"
            f"{body}\n"
            "\t\t\t};\n"
            f"\t\t\tname = {configuration};\n"
            "\t\t};")


def scheme_xml() -> str:
    target_id = uuid_for("target:JarvisApp")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "JarvisApp.app"
               BlueprintName = "JarvisApp"
               ReferencedContainer = "container:JarvisApp.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "JarvisApp.app"
            BlueprintName = "JarvisApp"
            ReferencedContainer = "container:JarvisApp.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "JarvisApp.app"
            BlueprintName = "JarvisApp"
            ReferencedContainer = "container:JarvisApp.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def render(root: pathlib.Path) -> str:
    app_root = root / APP_DIR
    core_root = root / CORE_DIR
    builder = ProjectBuilder(root)

    # ---- sources and resources -------------------------------------------
    app_files = collect(root, app_root)
    core_files = collect(root, core_root)
    if not app_files:
        raise SystemExit(f"no app sources found under {app_root}")

    source_build_files: list[str] = []
    resource_build_files: list[str] = []

    def group_children(files: list[pathlib.Path], base: pathlib.Path) -> list[str]:
        """Builds a PBXGroup tree that mirrors the folder structure on disk."""
        by_directory: dict[pathlib.Path, list[pathlib.Path]] = {}
        for path in files:
            by_directory.setdefault(path.parent, []).append(path)
        directories = {path.parent for path in files}

        def emit(directory: pathlib.Path) -> list[str]:
            result: list[str] = []
            for path in sorted(by_directory.get(directory, [])):
                if path.suffix == ".xcassets":
                    result.append(builder.file_reference(path, RESOURCE_TYPES[".xcassets"]))
                    resource_build_files.append(
                        builder.build_file(path, RESOURCE_TYPES[".xcassets"], "Resources"))
                else:
                    result.append(builder.file_reference(path, SOURCE_EXTENSIONS[".swift"]))
                    source_build_files.append(
                        builder.build_file(path, SOURCE_EXTENSIONS[".swift"], "Sources"))
            for child in sorted(directory_ for directory_ in directories
                                if directory_.parent == directory and directory_ != directory):
                result.append(builder.group(f"{base.name}/{child.relative_to(base)}", emit(child),
                                            path=child.name))
            return result

        return emit(base)

    app_group_children = group_children(app_files, app_root)
    core_group_children = group_children(core_files, core_root)

    # Info.plist is referenced but never compiled or copied (INFOPLIST_FILE handles it).
    info_reference = builder.file_reference(app_root / "Info.plist", PLIST_TYPE)
    app_group_children.insert(0, info_reference)

    app_group = builder.group(APP_DIR, app_group_children, path=APP_DIR)
    core_group = builder.group("JarvisCore", core_group_children, path=CORE_DIR)

    # ---- product ----------------------------------------------------------
    product_reference = builder.add(
        "product:JarvisApp.app",
        '{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; '
        'path = "JarvisApp.app"; sourceTree = BUILT_PRODUCTS_DIR; };')
    products_group = builder.group("Products", [product_reference])
    main_group = builder.group("main", [core_group, app_group, products_group])

    # ---- phases -----------------------------------------------------------
    sources_phase = builder.add("phase:Sources",
                                "{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
                                "\t\t\tfiles = (\n"
                                + "\n".join(f"\t\t\t\t{identifier}," for identifier in sorted(source_build_files))
                                + "\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")
    frameworks_phase = builder.add("phase:Frameworks",
                                   "{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
                                   "\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")
    resources_phase = builder.add("phase:Resources",
                                  "{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
                                  "\t\t\tfiles = (\n"
                                  + "\n".join(f"\t\t\t\t{identifier}," for identifier in sorted(resource_build_files))
                                  + "\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};")

    # ---- target and project ----------------------------------------------
    target_id = builder.add("target:JarvisApp",
                            "{\n"
                            "\t\t\tisa = PBXNativeTarget;\n"
                            "\t\t\tbuildConfigurationList = " + uuid_for("configlist:target") + ";\n"
                            "\t\t\tbuildPhases = (\n"
                            f"\t\t\t\t{sources_phase},\n"
                            f"\t\t\t\t{frameworks_phase},\n"
                            f"\t\t\t\t{resources_phase},\n"
                            "\t\t\t);\n"
                            "\t\t\tbuildRules = (\n\t\t\t);\n"
                            "\t\t\tdependencies = (\n\t\t\t);\n"
                            "\t\t\tname = " + TARGET_NAME + ";\n"
                            "\t\t\tproductName = " + TARGET_NAME + ";\n"
                            f"\t\t\tproductReference = {product_reference};\n"
                            "\t\t\tproductType = \"com.apple.product-type.application\";\n"
                            "\t\t};")

    project_id = builder.add("project:root",
                             "{\n"
                             "\t\t\tisa = PBXProject;\n"
                             "\t\t\tattributes = {\n"
                             "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
                             "\t\t\t\tLastSwiftUpdateCheck = 1500;\n"
                             "\t\t\t\tLastUpgradeCheck = 1500;\n"
                             "\t\t\t\tTargetAttributes = {\n"
                             f"\t\t\t\t\t{target_id} = {{\n"
                             "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
                             "\t\t\t\t\t};\n"
                             "\t\t\t\t};\n"
                             "\t\t\t};\n"
                             "\t\t\tbuildConfigurationList = " + uuid_for("configlist:project") + ";\n"
                             "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
                             "\t\t\tdevelopmentRegion = en;\n"
                             "\t\t\thasScannedForEncodings = 0;\n"
                             "\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
                             f"\t\t\tmainGroup = {main_group};\n"
                             f"\t\t\tproductRefGroup = {products_group};\n"
                             "\t\t\tprojectDirPath = \"\";\n"
                             "\t\t\tprojectRoot = \"\";\n"
                             "\t\t\ttargets = (\n"
                             f"\t\t\t\t{target_id},\n"
                             "\t\t\t);\n"
                             "\t\t};")

    builder.add("configlist:project",
                "{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{uuid_for('config:project:Debug')},\n"
                f"\t\t\t\t{uuid_for('config:project:Release')},\n"
                "\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n"
                "\t\t\tdefaultConfigurationName = Release;\n\t\t};")
    builder.add("configlist:target",
                "{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{uuid_for('config:target:Debug')},\n"
                f"\t\t\t\t{uuid_for('config:target:Release')},\n"
                "\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n"
                "\t\t\tdefaultConfigurationName = Release;\n\t\t};")
    builder.add("config:project:Debug", build_settings("Debug"))
    builder.add("config:project:Release", build_settings("Release"))
    builder.add("config:target:Debug", build_settings("Debug"))
    builder.add("config:target:Release", build_settings("Release"))

    # ---- serialise --------------------------------------------------------
    sections = {
        "PBXBuildFile": [],
        "PBXFileReference": [],
        "PBXFrameworksBuildPhase": [],
        "PBXGroup": [],
        "PBXNativeTarget": [],
        "PBXProject": [],
        "PBXResourcesBuildPhase": [],
        "PBXSourcesBuildPhase": [],
        "XCBuildConfiguration": [],
        "XCConfigurationList": [],
    }
    for identifier in builder.order:
        body = builder.objects[identifier]
        isa = body.split("isa = ", 1)[1].split(";", 1)[0]
        sections[isa].append((identifier, body))

    out: list[str] = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};",
                      "\tobjectVersion = 56;", "\tobjects = {", ""]
    for name in sections:
        entries = sections[name]
        if not entries:
            continue
        out.append(f"/* Begin {name} section */")
        for identifier, body in entries:
            out.append(f"\t\t{identifier} = {body}")
        out.append(f"/* End {name} section */")
        out.append("")
    out.append("\t};")
    out.append(f"\trootObject = {project_id};")
    out.append("}")
    out.append("")
    return "\n".join(out)


def write(root: pathlib.Path, check: bool) -> int:
    project_dir = root / f"{PROJECT_NAME}.xcodeproj"
    project_file = project_dir / "project.pbxproj"
    scheme_file = project_dir / "xcshareddata" / "xcschemes" / f"{TARGET_NAME}.xcscheme"
    content = render(root)

    # Never emit a project file that does not parse: this is the check that the
    # first macOS CI run proved was missing (see the note above about line 570).
    problems, stats = verify_project_text(content)
    if problems:
        for problem in problems:
            print(f"ERROR: {problem}")
        print("ERROR: refusing to write an unreadable project file")
        return 1
    print(f"verified generated project: {stats['objects']} objects, {stats['groups']} groups, "
          f"{stats['swift_sources']} Swift sources, {stats['build_configurations']} build configurations")

    if check:
        if not project_file.exists() or project_file.read_text() != content:
            problems.append(f"{project_file} is out of date — run scripts/generate_xcode_project.py")
        if not scheme_file.exists() or scheme_file.read_text() != scheme_xml():
            problems.append(f"{scheme_file} is out of date")
        # the committed file must parse too, not just the freshly rendered one
        if project_file.exists():
            committed, _ = verify_project_text(project_file.read_text())
            problems.extend(f"committed {project_file.name}: {p}" for p in committed)
        for problem in problems:
            print(f"ERROR: {problem}")
        return 1 if problems else 0

    project_dir.mkdir(parents=True, exist_ok=True)
    project_file.write_text(content)
    scheme_file.parent.mkdir(parents=True, exist_ok=True)
    scheme_file.write_text(scheme_xml())
    print(f"wrote {project_file}")
    print(f"wrote {scheme_file}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="verify the committed project matches the file tree")
    parser.add_argument("--verify", metavar="PROJECT_PBXPROJ",
                        help="parse an existing project file and check every reference")
    parser.add_argument("--repo-ios-dir",
                        default=str(pathlib.Path(__file__).resolve().parents[1] / "ios"))
    args = parser.parse_args()
    if args.verify:
        return verify_file(pathlib.Path(args.verify))
    return write(pathlib.Path(args.repo_ios_dir), args.check)


if __name__ == "__main__":
    sys.exit(main())
